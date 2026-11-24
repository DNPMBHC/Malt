import json
import struct
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock
import bench_real3d_ace_arch_watch as watch


def make_pe(machine, cert=False):
    dos=bytearray(128);dos[:2]=b"MZ";struct.pack_into("<I",dos,60,128)
    opt=bytearray(240);struct.pack_into("<H",opt,0,0x20B);struct.pack_into("<I",opt,108,16)
    coff=struct.pack("<4sHHIIIHH",b"PE\0\0",machine,1,0,0,0,len(opt),0x22)
    body=bytes(dos)+coff+bytes(opt)
    if cert:
        struct.pack_into("<II",opt,144,512,32)
        body=bytes(dos)+coff+bytes(opt)
        body=body.ljust(512,b"\0")+struct.pack("<IHH",32,0x200,2)+b"x"*24
    return body


def stalled_inventory_worker(connection, kwargs):
    time.sleep(10)


class AceArchWatchTests(unittest.TestCase):
    def test_architectures_and_certificate_presence_do_not_imply_trust(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/"driver.sys"
            for machine,arch in [(0x8664,"AMD64"),(0xaa64,"ARM64"),(0xa641,"ARM64EC")]:
                p.write_bytes(make_pe(machine,True));d=watch.parse_pe_header(p)
                self.assertTrue(d["pe_valid"]);self.assertEqual(d["architecture"],arch)
                self.assertTrue(d["has_embedded_signature"])
                self.assertEqual(d["embedded_signature_trust"],"not_verified")

    def test_invalid_certificate_extent_and_optional_header_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/"driver.sys";body=bytearray(make_pe(0x8664))
            struct.pack_into("<II",body,128+24+144,4096,256)
            p.write_bytes(body);d=watch.parse_pe_header(p)
            self.assertTrue(d["pe_valid"]);self.assertFalse(d["has_embedded_signature"])
            self.assertEqual(d["certificate_table_status"],"invalid_extent")
            p.write_bytes(body[:200]);self.assertFalse(watch.parse_pe_header(p)["pe_valid"])

    def test_arm64_dll_is_not_an_arm64_kernel_driver(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/"driver.sys").write_bytes(make_pe(0x8664));(root/"helper.dll").write_bytes(make_pe(0xaa64))
            before={p:p.read_bytes() for p in root.iterdir()}
            report=watch.scan_directory(root,(".sys",".dll"))
            self.assertEqual(report["verdict"],"amd64_only_no_arm64_sys")
            self.assertTrue(report["inventory_complete"]);self.assertFalse(report["has_native_arm64_driver"])
            self.assertEqual(before,{p:p.read_bytes() for p in root.iterdir()})
            (root/"native.sys").write_bytes(make_pe(0xaa64))
            self.assertTrue(watch.scan_directory(root)["has_native_arm64_driver"])

    def test_missing_target_and_limit_never_claim_complete_amd64_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            self.assertFalse(watch.scan_directory(root/"missing")["inventory_complete"])
            for i,m in enumerate([0x8664,0xaa64]):(root/f"driver-{i}.sys").write_bytes(make_pe(m))
            d=watch.scan_directory(root,max_files=1)
            self.assertFalse(d["inventory_complete"]);self.assertIn("file_limit",d["incomplete_reasons"])
            self.assertEqual(d["verdict"],"incomplete_inventory_no_arm64_observed")

    def test_unparsed_sys_prevents_complete_amd64_only_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/"valid.sys").write_bytes(make_pe(0x8664))
            (root/"unknown.sys").write_bytes(b"unreadable-format")
            report=watch.scan_directory(root)
            self.assertFalse(report["inventory_complete"])
            self.assertIn("unparsed_sys",report["incomplete_reasons"])
            self.assertEqual(report["verdict"],"incomplete_inventory_no_arm64_observed")

    def test_timeout_is_reported_and_does_not_become_negative_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/"driver.sys").write_bytes(make_pe(0x8664))
            with mock.patch.object(watch,"verify_windows",side_effect=TimeoutError):
                d=watch.scan_directory(root)
            self.assertIn("deadline",d["incomplete_reasons"])
            self.assertEqual(d["verdict"],"incomplete_inventory_no_arm64_observed")

    def test_cli_supervisor_terminates_a_blocking_inventory(self):
        with mock.patch.object(watch,"_scan_worker",stalled_inventory_worker):
            started=time.monotonic()
            report=watch.bounded_scan_directory(root=Path("module-x"),budget_seconds=0.15)
        self.assertLess(time.monotonic()-started,2)
        self.assertFalse(report["inventory_complete"])
        self.assertIn("deadline",report["incomplete_reasons"])
        self.assertEqual(report["verdict"],"incomplete_inventory_no_arm64_observed")

    def test_cli_and_neutral_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/"module-x.sys").write_bytes(make_pe(0xaa64));out=root/"inventory.json"
            self.assertEqual(watch.main([str(root),"--json-out",str(out)]),0)
            d=json.loads(out.read_text());self.assertEqual(d["owner"],"@DNPMBHC")
            self.assertTrue(d["files"][0]["relative_path"].startswith("artifact-"))

    def test_non_windows_signature_trust_is_explicitly_unverified(self):
        with mock.patch.object(watch.os,"name","posix"):
            self.assertEqual(watch.verify_windows(Path("module-x.sys"),float("inf"))["status"],"not_verified_platform")

if __name__=="__main__":unittest.main()
