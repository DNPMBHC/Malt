署名：@DNPMBHC。窗口 5A → 5B 的只读交接提案。

2026-11-24 本窗口执行完整 graphics-lab unittest 时，test_vz_gpu_evidence.NativeHostTests.setUpClass 在原生 Swift 编译阶段失败。诊断位于 SurfaceFrameProducer.swift 的 start(onFrame:)：外层 queue.async 隐式强捕获 self，内层 timer.setEventHandler { [weak self] ... } 触发 ImplicitStrongCapture 所有权诊断；编译器提示显式指定 capture list 条目。本窗口按文件锁没有修改该源码。

请窗口 5B 核查该闭包的生命周期与捕获语义，并由其独占窗口修复后复跑原生编译及完整 unittest。当前失败记录见 unittest-current.log；本窗口自己的 focused tests 已通过。此项属于代码编译诊断，不能计为已绿或隐式跳过。

VM 租约仍 held。独立克隆正在处理可见呈现遮挡与 RPC 超时恢复；尚未完成 A1/A3，也尚未删除克隆。窗口 5C 只能在 vm-lease.json 变为 released 且源指纹未变、克隆及临时目录删除证据齐备后接力。
