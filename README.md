# Swift DTS HDMA / DTS:X HDMA Research Encoder

Swift 6 原生 DTS 研究实现。编码、解码、容器抽取、DAMF 读取与声道变换均由本项目完成，运行时不依赖、不链接、也不调用第三方 codec。FFmpeg 只作为进程外的互操作验证器。

项目最终只提交两种产品：传统 `DTS HDMA` 与对象式 `DTS:X HDMA`。本文中的
`DTS HDMA` 与行业常用的 `DTS-HD Master Audio`/`DTS-HD MA` 是同一类别；
5.1 和 7.1 只是声道布局。完整命名与验收边界见
`Research/product-contract.md`。

## 已实现

- 48 kHz、packed 24-bit PCM；
- `XLL-Standalone` 内部诊断流：无 Core 的 ExSS/XLL，支持 2.0、5.1(side)、7.1，但不得作为最终 HDMA 成品；
- `DTS HDMA`：每个 AU 为 2,012-byte 5.1 DTS Core + ExSS/XLL；7.1 输入时 Core 层自动做 -3.0103 dB 等功率 5.1 折叠，XLL 层按官方互操作拓扑写成 `6+2` 层级 channel sets（`0x627` + `0x180`）并保留完整 7.1 无损；
- 单一 `HDMAEncoder` API 与结构验证器逐 AU 强制检查最终 DTS HDMA 的 Core+ExSS/XLL 契约；
- XLL 主层逐样本无损；产品兼容模式固定以 full-channel mask `0x3f` + `0x03` 独立承载完整 7.1 PCM，避免硬件端把大 residual 与不同 Core 重建结果相加造成电平异常/爆音；原 Core-residual 路径保留为研究策略；
- 原生 Swift 主层解码器，以及 FFmpeg 独立解码闭环；已用两条商业码流（IMAX Pre Show 5.1、dtsX Sound Unbound 7.1）的 PCM 完成再编码 SHA256 级闭环；
- M2TS 的 PAT/PMT/PES 与 Matroska `A_DTS`/lacing 原生抽取；
- RIFF/RF64 WAVE、7.1 到 5.1(side) 固定点等功率折叠；
- Dolby DAMF `.atmos`、`.atmos.metadata` 与 packed 24-bit CAF 原生读取；
- ADM BWF 原生读取：RIFF/RF64 `axml` ADM XML 与 `chna` 轨道映射直接解析，bed/object 分类、对象 block 位置/尺寸/增益轨迹均来自档案本身，不再依赖相邻 DAMF；
- IMF IAB 原生读取：MXF (ST 377-1) KLV 定位 clip-wrapped IAB essence（item 0x16/element 0x0D），SMPTE ST 2098-2 IAFrame/BedDefinition/ObjectDefinition/AudioDataPCM 逐帧解析，Plex 编码、DistanceXY/Z 位置反量化、每 sub-block pan 状态转为样本精确事件；AudioDataDLC (Annex B) 无损解码含 lattice→direct-form 预测器与 Rice/PCM 残差，两条熵路径与预测路径已用合成向量逐位闭环；
- DAMF 的 10 路 bed、对象 PCM、稀疏位置/大小/增益等状态按样本同步读取；
- `render-atmos-7.1.4`：bed + 全部对象按元数据轨迹（等功率 pan、Q30 定点、逐事件步进）确定性渲染为 DTS:X 7.1.4 authoring PCM；该阶段具备可审计的渲染/比较报告，但 Nature's Fury 对照仍显示非逐样本一致，不能作为通用 DTS:X 发射的完成证明；
- 原生 `DTSXPrivateFrameEncoder`：从任意四路 512-sample 高度 PCM 真实生成 branch-0/2 XLL-X frame，支持 0...3 阶 fixed prediction、1...10 阶 adaptive prediction、branch-2 成对去相关、signed-linear/Rice entropy、8...12-bit NAVI、prediction/NAVI/header CRC 与 32-bit alignment；每帧立即由独立 Swift 私有解码器逐样本复核；
- 原生 `DTSXNativeHDMAEncoder`：十二路 7.1.4 PCM → 7.1 compatibility bed Core+scalable XLL + 四高度 XLL-X → ExSS → `DTSHDHDR` 产品容器；主入口不读取、不复制也不重封装参考 DTS:X payload；
- DTS:X ExSS 已写入 23-byte asset descriptor / 40-byte header 的专用 decoder-navigation 信令；XLL-X offset 与 payload nibble count 每 AU 从实际 XLL 私有边界动态计算，普通 HDMA 继续保持 16-byte descriptor / 36-byte header；
- 自动 `-i/-o` 路由已将 DAMF、ADM BWF、IMF IAB 统一接到上述原生 DTS:X 路径；普通 5.1/7.1 WAVE 继续输出传统 DTS HDMA；
- Dolby speaker label 到 DTS speaker mask/order 的显式转换（Lss/Rss 保持侧环绕，Lrs/Rrs→Lsr/Rsr，Lts/Rts 高度对 -3.0103 dB 折入侧/后环绕）。

DTS Core 是兼容层研究编码器，使用真实 32-band QMF 与 DTS Core 语法；目前为固定 48 kHz/24-bit/5.1/512-sample/2012-byte profile，量化与 LFE 码率分配尚未做母带级听感优化。无损主层不受 Core 有损质量影响。

## DTS:X 边界

官方验证报告曾把原生输出识别为普通 `DTS-HD Master Audio / 8ch`。逐 bit
对照定位到旧 writer 只在 XLL band 尾部写入 XLL-X，却仍使用普通 HDMA 的
16-byte asset descriptor。现已从三份正式参考和五组 `test_X` 的全部 163,607
个 AU 验证 DTS:X descriptor 尾部关系：`profile=3`、实际 XLL-X byte offset、
24-bit signature `0x001145`、`2*(XLL-X bytes-24)` 与 6-bit zero pad。Swift
parser/writer/QC 均已类型化该结构；缺少此信令但含 XLL-X marker 的旧流会被
`verify-dtsx` 明确判为结构失败。官方验证器对新短向量的复测仍是外部验收项。

项目已完成对象编码前端，并已加入原生 XLL PBR 重组与 XLL-X 私有载荷提取：解析 common header、channel-set header 和 NAVI 段长后计算精确的 32-bit 对齐私有边界，不在 XLL entropy data 内盲搜标记。提供的 DTS:X 样本已提取 5,623/5,623 帧、13,055,692 字节私有载荷，0 次重同步；普通 HDMA 对照为 4,222 个 XLL 帧、0 个私有标记。逐帧索引、哈希、头部统计和可证伪假设见 `Research/xllx-reverse-engineering.md`。

Nature's Fury 的 10,159 个私有帧现已进入纯 Swift 四 coded-plane 严格解码 QC：3,644 帧满足当前零填充/非保留候选 profile。旧的固定 7-byte 前缀路径有 2,094 帧完成有界熵解码、1,669 帧逐样本恢复四路高度 PCM；对 0...15-byte 前缀做 Oracle 差分后，可证明 2,433 帧逐样本正确。由此得到的无 Oracle 严格入口只接受 branch 0 中“两个 segment 可解且尾部全零”的唯一候选，自动接受 2,362 帧，2,362 帧全部逐样本正确且 0 帧错配；全部 144 个单高度帧保持逐样本一致。

此外，`secondaryTenBitCode` 的高八位已闭合为四个 packed 2-bit plane indices：10,159/10,159 帧都是合法 permutation，全部 24 种 permutation 均出现；低两位把帧分到四个尚未完全闭合的私有分支。代码派生的 permutation 与前缀扫描得到的 2,433 个 sample-exact 帧全部一致。

授权单变量向量进一步闭合了 branch 0/2 的实际 PCM 语义。纯 Swift 验证器同时解码 Core、scalable 双 channel-set XLL 兼容床和私有四平面 XLL-X：`ALL_MUTE→Lfh` 与 `Lfh→Lfh+Rfh` 两步各覆盖 26,626 帧、13,632,512 samples，私有高度 PCM 经 Q15 `23170/32768` 折入公共 7.1 的 L/R 后均为 0 mismatch，另外七个声道也为 0 非预期变化。每步验证 53,252 个公共 XLL 帧实例、26,626 个私有 header/prediction CRC，以及 26,624 个 NAVI CRC；两个 48-byte priming 帧使用无 NAVI 静音形式。双高度流中 branch 0 为 24,355 帧、branch 2 为 2,271 帧，全部逐样本通过。报告见 `Build/Artifacts/Controlled-XLLX-PCM-20260723/controlled-pcm-verification.json`。

这项结果闭合了解码侧 routing、branch-2 pairwise decorrelation、预测、熵解码、NAVI、CRC 与兼容床增益关系。2026-07-24 的原生编码 profile 已加入自适应预测、branch-2 成对去相关，以及公开 XLL/私有 XLL-X 两层 Hybrid Rice 异常样本转义；生产搜索只允许证据闭合的 branch 0/2，branch 1/3 保持 parser-only。双层 Hybrid 的 258-AU 短流 branch 直方图为 `[249,0,9,0]`，公开床与四高度均为 0 mismatch。仍待闭合的是官方动态平面重排等码率决策和独立对象 ID/轨迹 metadata grammar；这些差异影响压缩率、对象保留与认证结论，不影响当前内部十二路 PCM 的逐样本闭环。

经典 Blu-ray DTS:X Master Audio 的 XLL-X 私有对象载荷语法不在 ETSI TS 102 114 中。单条未知源素材可以证实封装边界和稳定字段，但不能唯一决定对象 PCM、位置、bit allocation 与完整性字段的语义。

当前 DTS:X 输出不是“只写 sync word”：公共床、私有四高度 PCM、prediction、entropy、NAVI、CRC、ExSS 尺寸与产品容器均由输入重新编码，并经内部双层解码复核。FFmpeg 对抽出的 elementary stream 识别为 `DTS-HD MA + DTS:X`。尚未取得独立 DTS:X-aware renderer/AVR 对私有高度层的渲染证据，也尚未序列化独立对象 ID/轨迹 metadata，因此认证与对象保留仍是明确的外部验收门槛。ETSI DTS-UHD TS 103 491 是另一种流媒体/广播格式，未被替代进经典 Blu-ray DTS:X 扩展。

## Xcode 构建

```bash
xcodebuild -project Swift_DTSHDMA.xcodeproj \
  -scheme Swift_DTSHDMA \
  -configuration Release \
  -derivedDataPath Build \
  CODE_SIGNING_ALLOWED=NO build
```

工程只保留 `Swift_DTSHDMA/main.swift` 一个程序入口，不再使用 SwiftPM 清单或独立 CLI target。

## 命令行

```bash
Build/Products/Release/Swift_DTSHDMA -i INPUT -o OUTPUT.dtshd
# INPUT: 5.1/7.1 WAVE、DAMF .atmos(目录)、ADM BWF WAVE 或 IMF IAB MXF

Build/Products/Release/Swift_DTSHDMA extract-xllx \
  INPUT.dts OUTPUT.xllx OUTPUT_INDEX.json

Build/Products/Release/Swift_DTSHDMA survey-xllx \
  OUTPUT_INDEX.json OUTPUT.xllx OUTPUT_SURVEY.json

Build/Products/Release/Swift_DTSHDMA compare-xllx \
  BASE.json BASE.xllx VARIANT.json VARIANT.xllx OUTPUT_DIFF.json

# Verify a controlled old-height -> new-height routing change by rebuilding
# the 10-bit routing word and its protected CRC without copying entropy data.
Build/Products/Release/Swift_DTSHDMA verify-xllx-routing-remap \
  BASE.json BASE.xllx VARIANT.json VARIANT.xllx 2,0,1,3 OUTPUT.json

# Decode Core+XLL and private XLL-X for the authorized mute/Lfh/Lfh+Rfh
# single-variable matrix, then verify the exact Q15 compatibility-bed delta.
Build/Products/Release/Swift_DTSHDMA verify-xllx-controlled-pcm \
  ALL_MUTE.dtshd LFH_ONLY.dtshd LFH_RFH.dtshd OUTPUT.json

# Verify public XLL framing, the qualified 23-byte DTS:X ExSS descriptor,
# aligned private frames, and optionally exact bytes/SHA-256
Build/Products/Release/Swift_DTSHDMA verify-dtsx \
  INPUT.dtshd [EXPECTED.dtshd]

# Analyze the observed Core/ExSS/XLL/private-payload data flow
Build/Products/Release/Swift_DTSHDMA analyze-dtsx \
  INPUT.dtshd [OUTPUT.json]

# Strict four-plane private decoder QC against the aligned 7.1.4 PCM source
Build/Products/Release/Swift_DTSHDMA analyze-xllx-generic-decode \
  INPUT_INDEX.json INPUT.xllx SOURCE_DTSX_DIRECTORY OUTPUT.json

# Verify all supplied DTS:X delivery references (BD/DD/SCSA): frame structure,
# private-frame indexing, byte equality, and SHA-256
Build/Products/Release/Swift_DTSHDMA verify-dtsx-reference-set DTSX_REFERENCE_DIRECTORY

# Verify rebuilt BD/DD/SCSA outputs against Source_DTSX and their references:
# byte/SHA identity, public stream structure, and native Core+XLL 7.1 bed PCM
Build/Products/Release/Swift_DTSHDMA verify-dtsx-output-set \
  OUTPUT_DIRECTORY SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY

# Verify all supplied 7.1 HDMA delivery references against Source_HDMA
Build/Products/Release/Swift_DTSHDMA verify-hdma-reference-set \
  HDMA_REFERENCE_DIRECTORY SOURCE_HDMA_DIRECTORY

# Verify one DTS:X stream's public 7.1 compatibility bed against Source_DTSX
Build/Products/Release/Swift_DTSHDMA verify-dtsx-compatibility-bed-native \
  INPUT.dtshd SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]

# Explicitly decode native XLL-X, apply each frame's routing word, and compare
# semantic Lfh/Rfh/Lrh/Rrh PCM against the supplied 7.1.4 source.
Build/Products/Release/Swift_DTSHDMA verify-dtsx-private-heights-native \
  INPUT.dtshd SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]

# Atmos/DTS:X entry point; emits a qualification report and commits a stream
# only after the 7.1.4 renderer and private XLL-X encoder gates pass
Build/Products/Release/Swift_DTSHDMA encode-dtsx \
  -bd INPUT.atmos OUTPUT.dtshd SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY

# Encode any valid twelve-plane Source_DTSX-style 7.1.4 PCM set natively
Build/Products/Release/Swift_DTSHDMA encode-dtsx-source \
  -bd SOURCE_DTSX_DIRECTORY OUTPUT.dtshd DTSX_REFERENCE_DIRECTORY

# Encode one qualified Atmos master to all three delivery profiles
Build/Products/Release/Swift_DTSHDMA encode-dtsx-set \
  INPUT.atmos|ADM.wav|IAB.mxf OUTPUT_DIRECTORY \
  SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY

# Traditional DTS HDMA product (5.1/7.1 are layouts, not separate products)
Build/Products/Release/Swift_DTSHDMA encode-hdma INPUT_5.1.wav|INPUT_7.1.wav OUTPUT.dtshd
Build/Products/Release/Swift_DTSHDMA encode-hdma-source SOURCE_HDMA_DIRECTORY OUTPUT.dtshd [FRAME_COUNT]
Build/Products/Release/Swift_DTSHDMA verify-hdma INPUT.wav OUTPUT.dtshd
Build/Products/Release/Swift_DTSHDMA verify-core-syntax INPUT.dts|INPUT.dtshd
```

输入与输出映射：

| 输入 | 自动识别 | 输出 |
|---|---|---|
| 48 kHz/24-bit 5.1(side) WAVE | `5.1PCM` | `DTS HDMA`（5.1 Core + ExSS/XLL） |
| 48 kHz/24-bit 7.1 WAVE | `7.1PCM` | `DTS HDMA`（5.1 Core + 7.1 ExSS/XLL） |
| DAMF `.atmos` 文件或只含一个 `.atmos` 的目录 | `AtmosMaster` | 原生渲染 7.1.4，再编码 DTS:X HDMA |
| ADM BWF WAVE（原生 axml/chna 解析） | `AtmosMaster` | 原生渲染 7.1.4，再编码 DTS:X HDMA |
| IMF IAB MXF（ST 2098-2 essence） | `AtmosMaster` | 原生渲染 7.1.4，再编码 DTS:X HDMA |

同一 Nature's Fury 母带的三种表示（DAMF、ADM BWF、IMF IAB）均可被独立读取。自动编码接受交错多声道 5.1/7.1 WAVE，也接受 Atmos 表示；Atmos 先原生渲染为固定顺序的 7.1.4 PCM，再进入真实 Core+XLL+XLL-X 编码。每次自动交付同时写出 `OUTPUT.dtspbr` 和 `OUTPUT.dtshd_log.txt`，两者均由实际访问单元尺寸、输入声道数、时长和码率计算。当前私有层保存四高度 PCM，但不保存独立对象 ID/轨迹 metadata。`dtsx-plan` 固定 `L,R,C,LFE,Lss,Rss,Lsr,Rsr,Lfh,Rfh,Lrh,Rrh` 的 7.1.4 合约；`render-atmos-7.1.4` 生成对应的 12 路 PCM，`compare-atmos-7.1.4` 对 `Source_DTSX` 严格逐样本比较。

Atmos 分支读取 bed、对象 PCM 与同步元数据，并生成受检验的 7.1.4 PCM authoring 输入。输出的 elementary stream 含真实 XLL-X 高度 PCM 载荷；它不是普通 HDMA 改名。独立对象语义仍在渲染阶段折入 7.1.4，未以 ID/轨迹形式保留。

`verify-dtsx` 对每个 AU 复核 23-byte DTS:X asset descriptor 与其动态 XLL-X
offset/size，再对每个完整 XLL 帧复核 common/channel-set/NAVI CRC、PBR
重组、32-bit 对齐 XLL-X/IMAX 私有边界、零重同步和逐帧索引。给出第二个
`.dtshd` 参数时还会进行完整字节比较并分别计算 SHA-256；结构通过但字节
不同仍返回失败，避免把“播放器可解析”误报成“官方流逐字节一致”。

`verify-dtsx-reference-set` 会逐个检查 BD/DD/SCSA，而不是只检查其中一份
再复制结论。`verify-hdma-reference-set` 对 7.1 HDMA 的每个 AU 扫描 Core
和 ExSS 帧边界，并对 scalable 双 channel-set 的全部 XLL 帧执行原生熵解码；提供的官方 7.1 HDMA 使用 scalable、双 channel-set XLL，三份
文件的 canonical SHA-256 为
`66dbc33affd7eb4ef1ebc3fe3a27a3ecd5a68497e8e1a336899540266d9ad6d2`，报告会
逐文件确认该值；配套 `.dtspbr` 的 canonical SHA-256 为
`d4ea7d3b2c7476fe28e9ccbaf4b90725cc4970b41ac3606246f9e248d02a7a90`，并要求
BD/DD/SCSA 三份 PBR 逐字节相同。报告中的 `xllEntropyDecoded=true` 表示 Linear/Rice/Hybrid
Rice、预测、去相关与 scalable LSB 均已覆盖；纯 Swift fixed-point Core decoder
已接入同一逐样本闭环，三份官方 7.1 HDMA 的八声道各 5,200,000 个有效样本
均为 0 mismatch，384 个尾部补零样本均为 0，`allStreamsAreBitExact=true`。
两条命令都会把最终结论序列化为 JSON 的 `isCompliant` 字段；命令报告中的
`hardwareAcceptance` 固定为
`not-tested-locally`，真实功放仍需在硬件上播放同一文件并记录结果。

原生 Core PCM 已与 XLL residual、scalable LSB、Core inverse-scale 和
hierarchical downmix 合成闭环：裁掉 1,024 samples Core priming 后，官方
7.1 HDMA 的 8 个声道、5,200,000 samples/声道全部 0 mismatch，尾部 384
samples 全零。`verify-core-syntax` 进一步用纯 Swift 解析所有 Core frame header
和 primary audio coding header；Nature's Fury HDMA/DTS:X、Sound Unbound 与
IMAX 样本的所有 Core 帧均已完整通过。

`analyze-dtsx` 直接从裸流生成分层 JSON：Core sync/FSIZE、ExSS asset、XLL
channel-set/NAVI、32-bit 对齐私有载荷边界、帧时基和 SHA-256。遇到 scalable
channel set、Core residual 或私有 DTS:X 对象载荷时，报告会保留已验证的结构
并显式写出 PCM 验证状态，不把边界扫描当作私有语义解码。

`encode-hdma` 和 `verify-hdma` 固定输出 `profile=dtsHDMA`、
`streamKind=DTS HDMA`。每个 AU 都以 2,012 字节 DTS Core 开始并后接
ExSS/XLL；5.1/7.1 输入只改变 XLL 布局与 Core mapping，不改变产品类型。

自动 PCM 输出同样使用 DTS HDMA，最后一个不足 512 samples 的 AU 显式补零。
编码命令走 forward-only 路径，不默认执行整流解码或逐样本 QC；自动 JSON 明确
报告 `validationPerformed=false`。完整验证必须显式调用 `verify-hdma`、
`verify-dtsx-*` 等命令并提供 PCM 或 `.dtshd` 输入。编码进度只在主流、PBR 和
日志均已原子写入后报告一次 `100%`。无 Core 的 `encode-xll` 仅为诊断入口。

Nature's Fury 的 Atmos 三种入口（DAMF、ADM BWF、IMF IAB）和任意合法的
十二轨 `Source_DTSX` 风格输入现在都进入同一原生编码器。遗留
`DTSOfficialASTRebuilder` 仅保留为研究/差分代码，产品入口不再调用它。
2026-07-24 的 2,048-sample 三入口回归生成了 byte-identical 产品：每份 6 AU、
6 个私有帧、0 PCM mismatch、0 重同步，产品 SHA-256 均为
`9cd11a9c925dfe90f47c9be4dce07773a4eb34af192bfedccf9d25702efdd5eb`。
`encode-hdma-source` 读取八轨 `Source_HDMA`，固定输出 `dtsHDMA/DTS HDMA`。
可选 `FRAME_COUNT` 仅编码指定数量的 512-sample 源帧，用于短程差分回归；结构、
NAVI、字段宽度和逐样本无损闭环由显式验证命令执行。

7.1 XLL 编码按声道独立选择 linear/Rice 参数和 0...3 阶 fixed predictor，并在
2/4/8 段候选中按实际序列化字节数择优。当前 Nature's Fury 全长兼容性候选为
92,702,200 bytes / 6.84 Mbps；FFmpeg 解码后与官方文件的 41,600,000 个声道样本
全部一致。软件闭环不代替实际 AVR 验收，测试文件与报告见
`Build/Artifacts/Swift-7.1-HDMA-20260723-HWCOMPAT/`。

The `encode-dtsx-set` command renders one Atmos master once and independently
encodes the blue-ray-disc, digital-delivery, and scsa delivery names. Each
output passes native public-bed decode, private-height decode and DTS:X frame
structure checks. The three names currently share one deterministic syntax
profile, so identical input produces identical bytes by design.

Atmos DTS:X 使用独立的 `DTSXHDMAEncoder` API 和 `DTS:X HDMA` stream kind；
它复用公共 Core/XLL 基础设施，但必须额外通过 XLL-X/ObjectBed 资格闸门。

## Swift API

```swift
import SwiftDTSHDMA

let pcm = try WaveFile.read(from: inputURL)
let configuration = DTSHDMAEncoderConfiguration(
    format: pcm.format,
    profile: .dtsHDMA,
    tailPolicy: .zeroPad
)
let stream = try DTSHDMAEncoder(configuration: configuration).encode(pcm)
let reconstructed = try DTSHDMADecoder().decode(stream)
```

真实素材、哈希、闭环结果与规范映射见 `Research/validation-report.md` 和 `Research/spec-map.md`。本项目是互操作研究实现，不代表 DTS 官方认证；产品化、发行、商标与专利许可需另行审查。
