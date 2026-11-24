#!/usr/bin/env python3
"""Assemble the reviewable five-way baseline from captured evidence. @DNPMBHC."""
from __future__ import annotations
import argparse
import json
from pathlib import Path

import bench_real3d_runner as runner
import bench_real3d_support as support


def assemble(wine_manifest: Path, guest_manifest: Path, wine_dir: Path,
             guest_dir: Path, probe_source: Path, probe_exe: Path) -> dict:
    wine = json.loads(wine_manifest.read_text())
    guest = json.loads(guest_manifest.read_text())
    runs = wine['runs'] + guest['runs']
    workload = wine['workload']
    digest = support.sha256(probe_exe)
    if wine['probe_sha256'] != digest or wine['source_sha256'] != support.sha256(probe_source):
        raise RuntimeError('Wine source or executable binding does not match')
    if not runner.validate_baseline_runs(runs, workload, 3, digest):
        raise RuntimeError('All five arms must have three accepted rounds')
    for run in runs:
        directory = guest_dir if run['arm'] == 'guest_qemu_viogpu3d' else wine_dir
        relative = Path(run['files']['csv'])
        if relative.is_absolute() or len(relative.parts) != 1:
            raise RuntimeError('Evidence file must be a direct child of its run directory')
        csv = directory / relative
        if support.sha256(csv) != run['files']['csv_sha256']:
            raise RuntimeError('Frame CSV binding does not match')
        if runner.summarize_real3d_csv(csv) != run['csv_summary']:
            raise RuntimeError('Frame summary differs from captured CSV')
    return {
        'schema_version': 1, 'owner': '@DNPMBHC',
        'captured_at_utc': support.utc(),
        'experiment': 'phase5_dense_d3d11_async_swapchain_five_way_baseline',
        'five_way_comparison_valid': True,
        'workload': workload, 'rounds_per_arm': 3,
        'realWineExecuted': True, 'realGuestExecuted': True,
        'versions': wine['versions'],
        'immutable_digests': {
            'probe_source': support.sha256(probe_source), 'probe_exe': digest,
            'report_assembler': support.sha256(Path(__file__)),
            'runner': support.sha256(Path(runner.__file__)),
            **wine['component_digests'], **guest['digests']},
        'runs': runs, 'aggregate': runner.aggregate_arms(runs),
        'limitations': [
            'FPS includes the final GPU completion drain. Frame intervals measure CPU-side frame completion, not physical display or input latency.',
            'Table percentiles and FPS are arithmetic means of three independent per-round values.',
            '100 percent host CPU means one logical CPU. Host capacity percent divides this by the logical CPU count.',
            'Wine accounts for its dedicated process family; Guest accounts for the dedicated hypervisor and render process family.',
            'Process exit can lose the last CPU sampling interval. GPU hardware timestamps are not estimated.',
            'Results characterize this owned D3D11 workload and display configuration; they do not establish commercial game compatibility or an unthrottled upper bound.',
            'A compatibility adapter string is not a claim about the physical host GPU. No custom hardware identity overrides were configured.'
        ]
    }


def markdown(value: dict) -> str:
    rows = ['# 方案 B 真实 D3D11 高压力裁判基线', '',
            '署名：@DNPMBHC', '',
            '同一源码与 PE 二进制，五条路径各三轮。所有原生退出码为 0，'
            '帧 CSV 已重新计算并逐一校验 SHA-256。', '',
            '| 路径 | FPS | P50 ms | P95 ms | P99 ms | 宿主 CPU % | 宿主容量 % |',
            '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    labels = {'wine_dxmt': 'Wine DXMT', 'wine_d3dmetal': 'Wine D3DMetal',
              'wine_dxvk_kosmickrisp': 'Wine DXVK + KosmicKrisp',
              'wine_dxvk_moltenvk': 'Wine DXVK + MoltenVK',
              'guest_qemu_viogpu3d': 'QEMU WHQL viogpu3d'}
    for arm, label in labels.items():
        a = value['aggregate'][arm]
        keys = ['throughput_fps_mean', 'frame_interval_p50_ms_mean',
                'frame_interval_p95_ms_mean', 'frame_interval_p99_ms_mean',
                'host_cpu_percent_mean', 'host_capacity_percent_mean']
        rows.append('| ' + label + ' | ' + ' | '.join(f'{a[k]:.3f}' for k in keys) + ' |')
    w = value['workload']
    rows += ['', f"场景：{w['width']}×{w['height']}；每帧 {w['draws']:,} Draw、"
             f"{w['cb_updates']:,} 次常量缓冲更新、动态顶点缓冲、双 Pass 纹理采样；"
             f"{w['warmup']} 预热与 {w['frames']} 测量帧，三缓冲 SwapChain，Present(0,0)。",
             '', 'GPU 完成等待仅在预热后和测量末执行。帧间隔与 FPS 为三轮各自结果的算术平均；'
             'CPU 100% 表示占用一个逻辑核心。具体采样范围与显示条件见 JSON。', '',
             '探针源码 SHA-256：`' + value['immutable_digests']['probe_source'] + '`。',
             '探针 PE SHA-256：`' + value['immutable_digests']['probe_exe'] + '`。', '',
             '五维状态：实现完成、本地门禁另见最新 unittest 与安全记录、宿主与 Guest '
             '探针已实跑、厂商支持未知、商业游戏验证由 A1 单独取证。', '',
             '此基线用于比较方案 B 对相同负载的改善。物理显示延迟、输入延迟、未节流性能上限'
             '和商业游戏帧率均未由本次探针测量。', '']
    return '\n'.join(rows)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--wine-manifest', type=Path, required=True)
    parser.add_argument('--guest-manifest', type=Path, required=True)
    parser.add_argument('--wine-dir', type=Path, required=True)
    parser.add_argument('--guest-dir', type=Path, required=True)
    parser.add_argument('--probe-source', type=Path, required=True)
    parser.add_argument('--probe-exe', type=Path, required=True)
    args = parser.parse_args(argv)
    value = assemble(args.wine_manifest, args.guest_manifest, args.wine_dir,
                     args.guest_dir, args.probe_source, args.probe_exe)
    support.write_json(support.EVIDENCE / 'real3d-baseline.json', value)
    (support.EVIDENCE / 'real3d-baseline-report.md').write_text(support.redact(markdown(value)))
    print('Verified five-way baseline assembled')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
