import socket
import struct
import threading
import unittest

import command_protocol as protocol


class CommandProtocolTests(unittest.TestCase):
    def setUp(self):
        self.width, self.height = 1280, 720
        self.commands = protocol.command_batch(self.width)
        self.resource = protocol.seeded_resource(7)
        self.hello = protocol.hello_packet(self.width, self.height)

    def test_wire_header_is_little_endian_and_contains_no_pixel_payload(self):
        self.assertEqual(len(self.hello), 32)
        self.assertEqual(self.hello[:8], b"GFX1\x02\x00\x01\x00")
        values = struct.unpack("<6I", self.hello[8:])
        self.assertEqual(values, (60, 1280, 720, 512, 65536, 0))
        self.assertEqual(len(self.commands), 512)
        self.assertEqual(struct.unpack("<8I", self.commands[:32]), (1, 3, 0, 0, 512, 65536, 1280, 0))

    def test_cached_frames_retain_resource_until_full_update(self):
        session = protocol.CommandSession(self.hello)
        initial = protocol.frame_packet(0, self.width, self.height, self.commands, self.resource)
        session.consume(initial)
        first = session.resource
        cached = protocol.frame_packet(1, self.width, self.height)
        session.consume(cached)
        self.assertEqual(session.resource, first)
        self.assertEqual(len(cached), 32)
        updated = protocol.seeded_resource(7, 1)
        session.consume(protocol.frame_packet(2, self.width, self.height, b"", updated))
        self.assertNotEqual(session.resource, first)
        self.assertEqual(session.resource, updated)
        self.assertEqual(session.commands, self.commands)
        self.assertEqual(len(initial), 32 + 512 + 65536)

    def test_first_frame_requires_both_command_and_resource_initialization(self):
        for commands, resource in [(b"", b""), (self.commands, b""), (b"", self.resource)]:
            with self.subTest(commands=bool(commands), resource=bool(resource)):
                session = protocol.CommandSession(self.hello)
                with self.assertRaises(protocol.ProtocolError):
                    session.consume(protocol.frame_packet(0, self.width, self.height, commands, resource))

    def test_partial_resource_update_and_truncated_body_are_rejected(self):
        initial = protocol.frame_packet(0, self.width, self.height, self.commands, self.resource)
        session = protocol.CommandSession(self.hello)
        with self.assertRaises(protocol.ProtocolError):
            session.consume(initial[:-1])
        self.assertEqual(session.expected_sequence, 0)
        session.consume(initial)
        with self.assertRaises(protocol.ProtocolError):
            session.consume(protocol.frame_packet(1, self.width, self.height, b"", self.resource[:4]))
        self.assertEqual(session.resource, self.resource)
        self.assertEqual(session.expected_sequence, 1)

    def test_descriptor_validation_rejects_unsupported_draws_and_wrong_layout(self):
        original = list(struct.unpack("<8I", self.commands[:32]))
        mutations = [(0, 2), (1, 6), (2, 1), (3, 1), (4, 256),
                     (5, 65532), (6, 1279), (7, 1)]
        for index, value in mutations:
            with self.subTest(field=index):
                fields = original.copy()
                fields[index] = value
                bad = struct.pack("<8I", *fields) + self.commands[32:]
                session = protocol.CommandSession(self.hello)
                with self.assertRaises(protocol.ProtocolError):
                    session.consume(protocol.frame_packet(0, self.width, self.height, bad, self.resource))
                self.assertEqual(session.expected_sequence, 0)

    def test_sequence_dimensions_version_pixels_and_size_are_rejected(self):
        packet = protocol.frame_packet(0, self.width, self.height, self.commands, self.resource)
        bad_packets = []
        for offset, fmt, value in [(4, "<H", 1), (8, "<I", 1),
                                   (12, "<I", 64), (28, "<I", 1280 * 720 * 4)]:
            mutated = bytearray(packet)
            struct.pack_into(fmt, mutated, offset, value)
            bad_packets.append(bytes(mutated))
        for bad in bad_packets:
            with self.subTest(header=bad[:32]):
                with self.assertRaises(protocol.ProtocolError):
                    protocol.CommandSession(self.hello).consume(bad)
        with self.assertRaises(protocol.ProtocolError):
            protocol.PacketHeader(2, 0, 1280, 720, protocol.MAX_BODY_BYTES, 4).encode()

    def test_seeded_payload_matches_xorshift_u32_and_epoch_changes(self):
        self.assertEqual(protocol.seeded_resource(1, byte_count=8), bytes([33, 1, 197, 79, 209, 208, 26, 178]))
        self.assertEqual(protocol.seeded_resource(0, byte_count=8), protocol.seeded_resource(1, byte_count=8))
        self.assertNotEqual(protocol.seeded_resource(7, 0, 8), protocol.seeded_resource(7, 1, 8))

    def test_fragmented_ack_reads_exact_metrics_and_preserves_submillisecond_gpu_time(self):
        left, right = socket.socketpair()
        ack = protocol.PacketHeader(3, 9, 0, 0, 0, 0).encode() + protocol.METRICS.pack(1234, 168, 4096, 3686400)
        def sender():
            try:
                for offset in range(0, len(ack), 3):
                    right.sendall(ack[offset:offset + 3])
            finally:
                right.close()
        thread = threading.Thread(target=sender)
        thread.start()
        try:
            result = protocol.read_ack(left, 9)
            self.assertEqual(result["ack_bytes"], 56)
            self.assertEqual(result["host_gpu_ms"], 0.168)
            self.assertEqual(result["host_receive_ms"], 1.234)
            self.assertEqual(result["host_texture_bytes"], 3686400)
        finally:
            left.close()
            thread.join()

    def test_mismatched_ack_and_peer_close_are_failures(self):
        for ack in [protocol.PacketHeader(3, 2, 0, 0, 0, 0).encode(), b"GFX1"]:
            left, right = socket.socketpair()
            try:
                right.sendall(ack)
                right.close()
                with self.assertRaises(protocol.ProtocolError):
                    protocol.read_ack(left, 1)
            finally:
                left.close()


if __name__ == "__main__":
    unittest.main()
