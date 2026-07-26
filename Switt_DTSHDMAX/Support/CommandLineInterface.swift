import Foundation

private struct DTSXBatchEncodingReport: Encodable {
    let inputPath: String
    let outputDirectory: String
    let artifacts: [DTSXNativeFileEncodingReport]
    let allVerified: Bool
}

private struct LoadedDTS714Source {
    let master: AtmosMaster
    let rendered: DTS714PCMBuffer
}

public enum DTSHDMACommandLine {
    public static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        if command.hasPrefix("-") {
            if command == "-h" || command == "--help" {
                printUsage()
                return
            }
            let options = try parseAutomaticOptions(arguments)
            let progress = makeEncodingProgressReporter()
            let report = try DTSAutomaticEncoder.encode(
                inputURL: options.input,
                outputURL: options.output,
                frameRateOverride: options.frameRate
            ) { completed, total in
                progress(Int(completed), Int(total))
            }
            print(try jsonString(report))
            return
        }
#if DEBUG
        let values = Array(arguments.dropFirst())
        switch command {
        case "encode-xll":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("encode-xll requires INPUT.wav OUTPUT.dts")
            }
            let input = URL(fileURLWithPath: values[0])
            let output = URL(fileURLWithPath: values[1])
            let pcm = try WaveFile.read(from: input)
            let progress = makeEncodingProgressReporter()
            let stream = try DTSHDMAEncoder(configuration: DTSHDMAEncoderConfiguration(
                format: pcm.format,
                profile: .xllStandalone,
                tailPolicy: .reject
            )).encode(pcm, progress: { completed, total in
                progress(950 * completed / max(1, total), 1_000)
            })
            do { try stream.write(to: output, options: .atomic) } catch {
                throw DTSError.io("cannot write \(output.path): \(error.localizedDescription)")
            }
            progress(1_000, 1_000)
            print("encoded \(stream.count) bytes to \(output.path)")

        case "encode-core":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("encode-core requires INPUT.wav OUTPUT.dts")
            }
            let pcm = try WaveFile.read(from: URL(fileURLWithPath: values[0]))
            let progress = makeEncodingProgressReporter()
            progress(0, 1_000)
            let stream = try DTSCoreEncoder().encode(pcm)
            progress(950, 1_000)
            do { try stream.write(to: URL(fileURLWithPath: values[1]), options: .atomic) } catch {
                throw DTSError.io("cannot write \(values[1]): \(error.localizedDescription)")
            }
            progress(1_000, 1_000)
            print("encoded \(pcm.sampleCount) samples to \(stream.count) bytes of DTS Core")

        case "extract-core":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("extract-core requires INPUT.dtshd OUTPUT.dts")
            }
            print(try jsonString(DTSCoreExtractor.extract(
                inputURL: URL(fileURLWithPath: values[0]),
                outputURL: URL(fileURLWithPath: values[1])
            )))

        case "verify-core-syntax":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("verify-core-syntax requires INPUT.dts|INPUT.dtshd")
            }
            let report = try DTSCoreSyntaxVerifier.verify(
                inputURL: URL(fileURLWithPath: values[0])
            )
            print(try jsonString(report))
            guard report.allFramesParsed else {
                throw DTSError.malformed("DTS Core stream contains an unparsed frame")
            }

        case "decode-core":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("decode-core requires INPUT.dts|INPUT.dtshd OUTPUT.wav")
            }
            let decoded = try DTSCoreStreamDecoder.decode(
                inputURL: URL(fileURLWithPath: values[0])
            )
            try WaveFile.write(decoded, to: URL(fileURLWithPath: values[1]))
            print("decoded \(decoded.sampleCount) Core samples/channel to \(values[1])")

        case "verify-core-pcm":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("verify-core-pcm requires INPUT.dts|INPUT.dtshd ORACLE_32BIT.wav")
            }
            let report = try DTSCorePCMVerifier.verify(
                inputURL: URL(fileURLWithPath: values[0]),
                oraclePCMURL: URL(fileURLWithPath: values[1])
            )
            print(try jsonString(report))
            guard report.isBitExact else {
                throw DTSError.malformed("native DTS Core PCM differs from the oracle")
            }

        case "analyze-core-quality":
            guard (2...3).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "analyze-core-quality requires SOURCE_5.1.wav INPUT.dts|INPUT.dtshd [ALIGNMENT_SAMPLES]"
                )
            }
            let alignment: Int
            if values.count == 3 {
                guard let parsed = Int(values[2]), parsed >= 0 else {
                    throw DTSError.invalidArgument("ALIGNMENT_SAMPLES must be nonnegative")
                }
                alignment = parsed
            } else {
                alignment = XLLSyntax.coreCompatiblePrimingSampleCount
            }
            print(try jsonString(DTSCoreQualityAnalyzer.analyze(
                sourceURL: URL(fileURLWithPath: values[0]),
                inputURL: URL(fileURLWithPath: values[1]),
                alignmentSampleCount: alignment
            )))

        case "encode-hdma":
            let parsed = try parseFrameRateOption(values)
            guard parsed.arguments.count == 2 else {
                throw DTSError.invalidArgument(
                    "encode-hdma requires INPUT_5.1.wav|INPUT_7.1.wav OUTPUT.dtshd --frame-rate VALUE"
                )
            }
            let outputURL = try productOutputURL(parsed.arguments[1])
            let inputURL = URL(fileURLWithPath: parsed.arguments[0]).standardizedFileURL
            let pcm = try WaveFile.read(from: inputURL)
            guard pcm.format.layout == .fiveOneSide || pcm.format.layout == .sevenOne else {
                throw DTSError.unsupported("encode-hdma requires 5.1(side) or 7.1 PCM")
            }
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: parsed.frameRate,
                sourceDescription: "PCM WAVE"
            )
            let progress = makeEncodingProgressReporter()
            let stream = try HDMAEncoder(
                format: pcm.format,
                tailPolicy: .zeroPad,
                frameRate: frameRate
            ).encode(pcm, progress: { completed, total in
                progress(900 * completed / max(1, total), 1_000)
            })
            let artifacts = try DTSHDMADeliveryArtifactWriter.write(
                stream: stream,
                pcm: pcm,
                input: DTSHDMADeliveryInput(
                    inputURL: inputURL,
                    resolvedInputURL: inputURL,
                    detectedInput: pcm.format.layout == .sevenOne ? .sevenOnePCM : .fiveOnePCM,
                    sourceChannelCount: pcm.format.layout.channelCount
                ),
                outputURL: outputURL,
                frameRate: frameRate
            )
            progress(1_000, 1_000)
            print(try jsonString(artifacts))

        case "encode-hdma-source":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard (2...3).contains(arguments.count) else {
                throw DTSError.invalidArgument(
                    "encode-hdma-source requires SOURCE_HDMA_DIRECTORY OUTPUT.dtshd [FRAME_COUNT] --frame-rate VALUE"
                )
            }
            let outputURL = try productOutputURL(arguments[1])
            let source = try HDMAReferenceSetVerifier.loadSource(
                directory: URL(fileURLWithPath: arguments[0])
            )
            let pcm: PCMBuffer
            if arguments.count == 3 {
                guard let frameCount = Int(arguments[2]), frameCount > 0 else {
                    throw DTSError.invalidArgument("encode-hdma-source FRAME_COUNT must be positive")
                }
                let sampleCount = frameCount * XLLSyntax.frameSampleCount
                guard sampleCount <= source.sampleCount else {
                    throw DTSError.valueOutOfRange(
                        field: "encode-hdma-source FRAME_COUNT",
                        value: String(frameCount)
                    )
                }
                pcm = try source.frame(at: 0, count: sampleCount)
            } else {
                pcm = source
            }
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: parsed.frameRate,
                sourceDescription: "HDMA source-directory PCM"
            )
            let progress = makeEncodingProgressReporter()
            let stream = try HDMAEncoder(
                format: pcm.format,
                tailPolicy: .zeroPad,
                frameRate: frameRate
            ).encode(pcm, progress: { completed, total in
                progress(900 * completed / max(1, total), 1_000)
            })
            let artifacts = try DTSHDMADeliveryArtifactWriter.write(
                stream: stream,
                pcm: pcm,
                input: DTSHDMADeliveryInput(
                    inputURL: URL(fileURLWithPath: arguments[0]),
                    resolvedInputURL: URL(fileURLWithPath: arguments[0]),
                    detectedInput: pcm.format.layout == .sevenOne ? .sevenOnePCM : .fiveOnePCM,
                    sourceChannelCount: pcm.format.layout.channelCount
                ),
                outputURL: outputURL,
                frameRate: frameRate
            )
            progress(1_000, 1_000)
            print(try jsonString(artifacts))

        case "decode-xll":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("decode-xll requires INPUT.dts OUTPUT.wav")
            }
            let input = URL(fileURLWithPath: values[0])
            let output = URL(fileURLWithPath: values[1])
            let stream: Data
            do { stream = try Data(contentsOf: input, options: .mappedIfSafe) } catch {
                throw DTSError.io("cannot read \(input.path): \(error.localizedDescription)")
            }
            let pcm = try DTSHDMADecoder().decode(stream)
            try WaveFile.write(pcm, to: output)
            print("decoded \(pcm.sampleCount) samples, \(pcm.format.layout.rawValue)")

        case "verify-hdma":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard (2...3).contains(arguments.count) else {
                throw DTSError.invalidArgument(
                    "verify-hdma requires INPUT.wav OUTPUT.dtshd [OUTPUT_DECODED.wav] --frame-rate VALUE"
                )
            }
            let input = try WaveFile.read(from: URL(fileURLWithPath: arguments[0]))
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: parsed.frameRate,
                sourceDescription: "PCM WAVE"
            )
            let result = try DTSHDMAVerifier.verify(
                input,
                profile: .dtsHDMA,
                tailPolicy: .zeroPad,
                frameRate: frameRate
            )
            let streamURL = try productOutputURL(arguments[1])
            do {
                try result.stream.write(to: streamURL, options: .atomic)
            } catch {
                throw DTSError.io("cannot write \(streamURL.path): \(error.localizedDescription)")
            }
            if arguments.count == 3 {
                try WaveFile.write(result.decodedPCM, to: URL(fileURLWithPath: arguments[2]))
            }
            print(try jsonString(result.report))

        case "hash-pcm":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("hash-pcm requires INPUT.wav")
            }
            let pcm = try WaveFile.read(from: URL(fileURLWithPath: values[0]))
            print(try jsonString(PCMHasher.report(pcm)))

        case "sha256":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("sha256 requires INPUT")
            }
            print(try SHA256Hasher.hash(fileAt: URL(fileURLWithPath: values[0])))

        case "md5":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("md5 requires INPUT")
            }
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: values[0]), options: .mappedIfSafe)
            } catch {
                throw DTSError.io("cannot read \(values[0]): \(error.localizedDescription)")
            }
            print(MD5Hasher.hash(data))

        case "generate":
            guard values.count == 3, let frameCount = Int(values[1]) else {
                throw DTSError.invalidArgument("generate requires stereo|5.1|7.1 FRAME_COUNT OUTPUT.wav")
            }
            let layout: DTSChannelLayout
            switch values[0] {
            case "stereo", "2.0": layout = .stereo
            case "5.1", "5.1(side)": layout = .fiveOneSide
            case "7.1": layout = .sevenOne
            default: throw DTSError.invalidArgument("layout must be stereo, 5.1, or 7.1")
            }
            let pcm = try SyntheticPCM.deterministic(layout: layout, frameCount: frameCount)
            try WaveFile.write(pcm, to: URL(fileURLWithPath: values[2]))
            print("generated \(pcm.sampleCount) samples, \(layout.rawValue)")

        case "compare":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("compare requires EXPECTED.wav ACTUAL.wav")
            }
            let expected = try WaveFile.read(from: URL(fileURLWithPath: values[0]))
            let actual = try WaveFile.read(from: URL(fileURLWithPath: values[1]))
            let comparison = try PCMComparator.compare(expected, actual)
            print(try jsonString(comparison))
            if !comparison.isBitExact { throw DTSError.malformed("PCM comparison is not bit-exact") }

        case "compare-padded":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("compare-padded requires EXPECTED.wav PADDED_ACTUAL.wav")
            }
            let expected = try WaveFile.read(from: URL(fileURLWithPath: values[0]))
            let actual = try WaveFile.read(from: URL(fileURLWithPath: values[1]))
            let comparison = try PCMComparator.compareWithZeroPadding(expected: expected, paddedActual: actual)
            print(try jsonString(comparison))
            if !comparison.isBitExact { throw DTSError.malformed("padded PCM comparison is not bit-exact") }

        case "render-7.1-to-5.1":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("render-7.1-to-5.1 requires INPUT.wav OUTPUT.wav")
            }
            let input = try WaveFile.read(from: URL(fileURLWithPath: values[0]))
            let rendered = try DTSBedRenderer.sevenOneToFiveOne(input)
            try WaveFile.write(rendered, to: URL(fileURLWithPath: values[1]))
            print("rendered \(rendered.sampleCount) samples to \(rendered.format.layout.rawValue)")

        case "inspect":
            guard (1...2).contains(values.count) else {
                throw DTSError.invalidArgument("inspect requires INPUT.dts [ACCESS_UNIT_COUNT]")
            }
            let count = values.count == 2 ? Int(values[1]) ?? 0 : 8
            let infos = try DTSStreamInspector().inspect(
                url: URL(fileURLWithPath: values[0]),
                maximumAccessUnits: count
            )
            print(try jsonString(infos))

        case "analyze-dtsx":
            guard (1...2).contains(values.count) else {
                throw DTSError.invalidArgument("analyze-dtsx requires INPUT.dts [OUTPUT.json]")
            }
            let report = try DTSAlgorithmAnalyzer.analyze(
                inputURL: URL(fileURLWithPath: values[0])
            )
            if values.count == 2 {
                let output = URL(fileURLWithPath: values[1]).standardizedFileURL
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                do {
                    try encoder.encode(report).write(to: output, options: .atomic)
                } catch {
                    throw DTSError.io("cannot write DTS algorithm report: \(error.localizedDescription)")
                }
            }
            print(try jsonString(report))

        case "diff-dtshd":
            guard (2...3).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "diff-dtshd requires BASELINE.dts VARIANT.dts [ACCESS_UNIT_COUNT]"
                )
            }
            let count = values.count == 3 ? Int(values[2]) ?? 0 : 8
            let report = try DTSHDFrameDifferential().compare(
                baselineURL: URL(fileURLWithPath: values[0]),
                variantURL: URL(fileURLWithPath: values[1]),
                maximumAccessUnits: count
            )
            print(try jsonString(report))

        case "diff-dtshd-summary":
            guard (2...3).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "diff-dtshd-summary requires BASELINE.dts VARIANT.dts [ACCESS_UNIT_COUNT]"
                )
            }
            let count = values.count == 3 ? Int(values[2]) ?? 0 : 8
            let differential = DTSHDFrameDifferential()
            let report = try differential.compare(
                baselineURL: URL(fileURLWithPath: values[0]),
                variantURL: URL(fileURLWithPath: values[1]),
                maximumAccessUnits: count
            )
            print(try jsonString(differential.summary(of: report)))

        case "qc-dtshd":
            guard (1...2).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "qc-dtshd requires INPUT.dts [EXPECTED.dts]"
                )
            }
            let report = try DTSFrameQualityControl.inspect(
                inputURL: URL(fileURLWithPath: values[0]),
                expectedURL: values.count == 2 ? URL(fileURLWithPath: values[1]) : nil
            )
            print(try jsonString(report))
            guard report.isStructurallyValid,
                  report.expectedPath == nil || report.isByteExactToExpected else {
                throw DTSError.malformed("DTS frame QC failed structural or byte-exact verification")
            }

        case "compare-dtsx-bitrate":
            guard (2...3).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "compare-dtsx-bitrate requires REFERENCE.dtshd CANDIDATE.dtshd [ACCESS_UNIT_COUNT]"
                )
            }
            let maximumAccessUnitCount: Int?
            if values.count == 3 {
                guard let parsed = Int(values[2]), parsed > 0 else {
                    throw DTSError.invalidArgument("ACCESS_UNIT_COUNT must be positive")
                }
                maximumAccessUnitCount = parsed
            } else {
                maximumAccessUnitCount = nil
            }
            print(try jsonString(DTSBitrateParityVerifier.compare(
                referenceURL: URL(fileURLWithPath: values[0]),
                candidateURL: URL(fileURLWithPath: values[1]),
                maximumAccessUnitCount: maximumAccessUnitCount
            )))

        case "inspect-dtsx-reference":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("inspect-dtsx-reference requires DTSX_REFERENCE_DIRECTORY")
            }
            print(try jsonString(DTSXReferenceSet.inspect(
                directory: URL(fileURLWithPath: values[0])
            )))

        case "verify-dtsx-reference-set":
            guard values.count == 1 else {
                throw DTSError.invalidArgument(
                    "verify-dtsx-reference-set requires DTSX_REFERENCE_DIRECTORY"
                )
            }
            let report = try DTSXReferenceSetVerifier.verify(
                directory: URL(fileURLWithPath: values[0])
            )
            print(try jsonString(report))
            guard report.isCompliant else {
                throw DTSError.malformed(
                    "DTS:X reference set failed structural, byte, or SHA-256 verification"
                )
            }

        case "verify-dtsx-output-set":
            guard values.count == 3 else {
                throw DTSError.invalidArgument(
                    "verify-dtsx-output-set requires OUTPUT_DIRECTORY SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY"
                )
            }
            let report = try DTSXReferenceSetVerifier.verifyOutputs(
                outputDirectory: URL(fileURLWithPath: values[0]),
                sourceDirectory: URL(fileURLWithPath: values[1]),
                referenceDirectory: URL(fileURLWithPath: values[2])
            )
            print(try jsonString(report))
            guard report.isCompliant else {
                throw DTSError.malformed(
                    "DTS:X output set failed byte, SHA-256, structure, or compatibility-bed verification"
                )
            }

        case "verify-hdma-reference-set":
            guard values.count == 2 else {
                throw DTSError.invalidArgument(
                    "verify-hdma-reference-set requires HDMA_REFERENCE_DIRECTORY SOURCE_HDMA_DIRECTORY"
                )
            }
            let report = try HDMAReferenceSetVerifier.verify(
                referenceDirectory: URL(fileURLWithPath: values[0]),
                sourceDirectory: URL(fileURLWithPath: values[1])
            )
            print(try jsonString(report))
            guard report.isCompliant else {
                throw DTSError.malformed(
                    "HDMA reference set failed byte or PCM verification"
                )
            }

        case "inspect-dtsx-source":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("inspect-dtsx-source requires SOURCE_DTSX_DIRECTORY")
            }
            print(try jsonString(DTS714SourceSet.inspect(
                directory: URL(fileURLWithPath: values[0])
            )))

        case "verify-dtsx":
            guard (1...2).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "verify-dtsx requires INPUT.dtshd [EXPECTED.dtshd]"
                )
            }
            let report = try DTSXObjectExtractor.verify(
                inputURL: URL(fileURLWithPath: values[0]),
                expectedReferenceURL: values.count == 2
                    ? URL(fileURLWithPath: values[1])
                    : nil
            )
            print(try jsonString(report))
            guard report.isStructurallyValid else {
                throw DTSError.malformed("DTS:X stream failed structural verification")
            }
            if values.count == 2, report.byteIdenticalToExpected != true {
                throw DTSError.malformed("DTS:X stream differs from the expected byte oracle")
            }

        case "verify-official-ast":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("verify-official-ast requires INPUT.dtshd")
            }
            let report = try DTSOfficialASTVerifier.verify(
                inputURL: URL(fileURLWithPath: values[0])
            )
            print(try jsonString(report))
            guard report.allAccessUnitsRoundTripExactly else {
                throw DTSError.malformed("official DTS-HD AST serialization differs from its input")
            }

        case "verify-xll-pbr":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("verify-xll-pbr requires INPUT.dtshd")
            }
            let report = try XLLPBRVerifier.verify(inputURL: URL(fileURLWithPath: values[0]))
            print(try jsonString(report))
            guard report.allFramesParsed else {
                throw DTSError.malformed("XLL PBR verification found no complete frames")
            }

        case "verify-xll-channel-set-pcm":
            guard values.count >= 4, let channelSetIndex = Int(values[1]) else {
                throw DTSError.invalidArgument(
                    "verify-xll-channel-set-pcm requires INPUT.dtshd CHANNEL_SET_INDEX EXPECTED_CHANNEL_0.wav EXPECTED_CHANNEL_1.wav [...]"
                )
            }
            let report = try XLLChannelSetPCMVerifier.verify(
                inputURL: URL(fileURLWithPath: values[0]),
                channelSetIndex: channelSetIndex,
                expectedChannelURLs: values.dropFirst(2).map { URL(fileURLWithPath: $0) }
            )
            print(try jsonString(report))
            guard report.isBitExactWithZeroPadding else {
                throw DTSError.malformed("XLL channel-set PCM differs from expected PCM")
            }

        case "inspect-xll-frame-decode":
            guard values.count == 2, let frameIndex = Int(values[1]) else {
                throw DTSError.invalidArgument("inspect-xll-frame-decode requires INPUT.dtshd FRAME_INDEX")
            }
            print(try jsonString(XLLFrameDecodeInspector.inspect(
                inputURL: URL(fileURLWithPath: values[0]),
                frameIndex: frameIndex
            )))

        case "verify-xll-decode":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("verify-xll-decode requires INPUT.dtshd")
            }
            let report = try XLLDecodeVerifier.verify(inputURL: URL(fileURLWithPath: values[0]))
            print(try jsonString(report))
            guard report.allFramesDecoded else {
                throw DTSError.malformed("XLL stream contains no decoded frames")
            }

        case "verify-xll-core-oracle":
            guard values.count == 3 else {
                throw DTSError.invalidArgument(
                    "verify-xll-core-oracle requires INPUT.dtshd CORE_ORACLE_5.1.wav SOURCE_HDMA_DIRECTORY"
                )
            }
            let report = try XLLCoreOracleVerifier.verify(
                inputURL: URL(fileURLWithPath: values[0]),
                coreOraclePCMURL: URL(fileURLWithPath: values[1]),
                sourceDirectory: URL(fileURLWithPath: values[2])
            )
            print(try jsonString(report))
            guard report.isBitExactWithZeroPadding else {
                throw DTSError.malformed("Core oracle + XLL residual differs from source PCM")
            }

        case "verify-xll-core-native":
            guard values.count == 2 else {
                throw DTSError.invalidArgument(
                    "verify-xll-core-native requires INPUT.dtshd SOURCE_HDMA_DIRECTORY"
                )
            }
            let report = try XLLCoreNativeVerifier.verify(
                inputURL: URL(fileURLWithPath: values[0]),
                sourceDirectory: URL(fileURLWithPath: values[1])
            )
            print(try jsonString(report))
            guard report.isBitExactWithZeroPadding else {
                throw DTSError.malformed("native Core + XLL residual differs from source PCM")
            }

        case "verify-dtsx-compatibility-bed-native":
            guard (2...3).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "verify-dtsx-compatibility-bed-native requires INPUT.dtshd SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]"
                )
            }
            let maximumFrames: Int?
            if values.count == 3 {
                guard let parsedCount = Int(values[2]), parsedCount > 0 else {
                    throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
                }
                maximumFrames = parsedCount
            } else {
                maximumFrames = nil
            }
            let report = try XLLCoreNativeVerifier.verifyDTSXCompatibilityBed(
                inputURL: URL(fileURLWithPath: values[0]),
                sourceDirectory: URL(fileURLWithPath: values[1]),
                maximumSourceFrameCount: maximumFrames
            )
            print(try jsonString(report))
            guard report.isBitExactWithZeroPadding else {
                throw DTSError.malformed("native DTS:X compatibility bed differs from the logged 7.1 downmix")
            }

        case "verify-dtsx-compatibility-bed-oracle":
            guard (3...4).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "verify-dtsx-compatibility-bed-oracle requires INPUT.dtshd CORE_ORACLE_5.1.wav SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]"
                )
            }
            let maximumFrames: Int?
            if values.count == 4 {
                guard let parsedCount = Int(values[3]), parsedCount > 0 else {
                    throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
                }
                maximumFrames = parsedCount
            } else {
                maximumFrames = nil
            }
            let report = try XLLCoreOracleVerifier.verifyDTSXCompatibilityBed(
                inputURL: URL(fileURLWithPath: values[0]),
                coreOraclePCMURL: URL(fileURLWithPath: values[1]),
                sourceDirectory: URL(fileURLWithPath: values[2]),
                maximumSourceFrameCount: maximumFrames
            )
            print(try jsonString(report))
            guard report.isBitExactWithZeroPadding else {
                throw DTSError.malformed(
                    "independent Core oracle + XLL differs from the DTS:X compatibility bed"
                )
            }

        case "verify-dtsx-private-heights-native":
            guard (2...3).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "verify-dtsx-private-heights-native requires INPUT.dtshd SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]"
                )
            }
            let maximumFrames: Int?
            if values.count == 3 {
                guard let parsedCount = Int(values[2]), parsedCount > 0 else {
                    throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
                }
                maximumFrames = parsedCount
            } else {
                maximumFrames = nil
            }
            let report = try DTSXPrivateHeightVerifier.verify(
                inputURL: URL(fileURLWithPath: values[0]),
                source: DTS714SourceSet.load(
                    directory: URL(fileURLWithPath: values[1])
                ),
                maximumSourceFrameCount: maximumFrames
            )
            print(try jsonString(report))
            guard report.isBitExact else {
                throw DTSError.malformed(
                    "native XLL-X routed height PCM differs from the explicit source"
                )
            }

        case "write-dtsx-compatibility-bed-source":
            guard (2...3).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "write-dtsx-compatibility-bed-source requires SOURCE_DTSX_DIRECTORY OUTPUT_7.1.wav [SOURCE_FRAME_COUNT]"
                )
            }
            let complete = try DTS714SourceSet.load(
                directory: URL(fileURLWithPath: values[0])
            )
            let source: DTS714PCMBuffer
            if values.count == 3 {
                guard let frameCount = Int(values[2]), frameCount > 0 else {
                    throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
                }
                let sampleCount = frameCount * XLLSyntax.frameSampleCount
                guard sampleCount <= complete.sampleCount else {
                    throw DTSError.valueOutOfRange(
                        field: "DTS:X compatibility source frame count",
                        value: String(frameCount)
                    )
                }
                source = try DTS714PCMBuffer(
                    planes: complete.planes.map { Array($0.prefix(sampleCount)) }
                )
            } else {
                source = complete
            }
            let bed = try DTS714CompatibilityBedRenderer.render(source)
            try WaveFile.write(bed, to: URL(fileURLWithPath: values[1]))
            print(try jsonString(PCMHasher.report(bed)))

        case "verify-xllx-native-encoder":
            guard values.isEmpty else {
                throw DTSError.invalidArgument("verify-xllx-native-encoder takes no arguments")
            }
            print(try jsonString(DTSXPrivateEncoderVerifier.verify()))

        case "verify-xllx-official-inverse":
            guard (3...4).contains(values.count) else {
                throw DTSError.invalidArgument(
                    "verify-xllx-official-inverse requires INPUT_INDEX.json INPUT.xllx OUTPUT.json [MAX_FRAMES]"
                )
            }
            let maximumFrameCount: Int?
            if values.count == 4 {
                guard let parsed = Int(values[3]), parsed > 0 else {
                    throw DTSError.invalidArgument("MAX_FRAMES must be positive")
                }
                maximumFrameCount = parsed
            } else {
                maximumFrameCount = nil
            }
            let report = try DTSXPrivateOfficialInverseVerifier.verify(
                indexURL: URL(fileURLWithPath: values[0]),
                payloadURL: URL(fileURLWithPath: values[1]),
                outputURL: URL(fileURLWithPath: values[2]),
                maximumFrameCount: maximumFrameCount
            )
            print(try jsonString(report))
            guard report.reencodedFrameCount > 0,
                  report.byteExactFrameCount == report.reencodedFrameCount,
                  report.equalFrameByteCountFrameCount == report.reencodedFrameCount,
                  report.originalTotalByteCount == report.reencodedTotalByteCount,
                  report.failures.isEmpty else {
                throw DTSError.malformed(
                    "official XLL-X inverse regression is not frame- and byte-exact"
                )
            }

        case "verify-dtsx-native-encoder":
            guard values.isEmpty else {
                throw DTSError.invalidArgument("verify-dtsx-native-encoder takes no arguments")
            }
            print(try jsonString(DTSXNativeEncoderVerifier.verify()))

        case "encode-dtsx-native-source":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard (2...3).contains(arguments.count) else {
                throw DTSError.invalidArgument(
                    "encode-dtsx-native-source requires SOURCE_DTSX_DIRECTORY OUTPUT.dtshd [SOURCE_FRAME_COUNT] --frame-rate VALUE"
                )
            }
            let maximumFrames: Int?
            if arguments.count == 3 {
                guard let parsedCount = Int(arguments[2]), parsedCount > 0 else {
                    throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
                }
                maximumFrames = parsedCount
            } else {
                maximumFrames = nil
            }
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: parsed.frameRate,
                sourceDescription: "DTS:X source-directory PCM"
            )
            let source = try DTS714SourceSet.load(
                directory: URL(fileURLWithPath: arguments[0])
            )
            let report = try DTSXNativeHDMAEncoder().encode(
                source: source,
                to: try productOutputURL(arguments[1]),
                frameRate: frameRate,
                maximumSourceFrameCount: maximumFrames,
                progress: makeEncodingProgressReporter()
            )
            print(try jsonString(report))

        case "encode-dtsx-native":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard (2...3).contains(arguments.count) else {
                throw DTSError.invalidArgument(
                    "encode-dtsx-native requires INPUT.atmos|ADM.wav|IAB.mxf OUTPUT.dtshd [SOURCE_FRAME_COUNT] [--frame-rate VALUE]"
                )
            }
            let maximumFrames: Int?
            if arguments.count == 3 {
                guard let parsedCount = Int(arguments[2]), parsedCount > 0 else {
                    throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
                }
                maximumFrames = parsedCount
            } else {
                maximumFrames = nil
            }
            let loaded = try loadAndRenderDTS714(
                path: arguments[0],
                maximumSourceFrameCount: maximumFrames
            )
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: loaded.master.framesPerSecond,
                override: parsed.frameRate,
                sourceDescription: "Atmos master (\(loaded.master.version))"
            )
            let report = try DTSXNativeHDMAEncoder().encode(
                source: loaded.rendered,
                to: try productOutputURL(arguments[1]),
                frameRate: frameRate,
                maximumSourceFrameCount: maximumFrames,
                progress: makeEncodingProgressReporter()
            )
            print(try jsonString(report))

        case "encode-dtsx-native-wave":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard (2...3).contains(arguments.count) else {
                throw DTSError.invalidArgument(
                    "encode-dtsx-native-wave requires INPUT_7.1.4.wav OUTPUT.dtshd [SOURCE_FRAME_COUNT] --frame-rate VALUE"
                )
            }
            let maximumFrames: Int?
            if arguments.count == 3 {
                guard let parsedCount = Int(arguments[2]), parsedCount > 0 else {
                    throw DTSError.invalidArgument("SOURCE_FRAME_COUNT must be positive")
                }
                maximumFrames = parsedCount
            } else {
                maximumFrames = nil
            }
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: parsed.frameRate,
                sourceDescription: "7.1.4 PCM WAVE"
            )
            let report = try DTSXNativeHDMAEncoder().encode(
                source: WaveFile.readDTS714(
                    from: URL(fileURLWithPath: arguments[0]).standardizedFileURL
                ),
                to: try productOutputURL(arguments[1]),
                frameRate: frameRate,
                maximumSourceFrameCount: maximumFrames,
                progress: makeEncodingProgressReporter()
            )
            print(try jsonString(report))

        case "encode-dtsx":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard arguments.count == 5 else {
                throw DTSError.invalidArgument(
                    "encode-dtsx requires MODE INPUT.atmos|ADM.wav|IAB.mxf OUTPUT.dtshd SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY [--frame-rate VALUE]"
                )
            }
            let mode = try DTSXDeliveryMode(option: arguments[0])
            let input = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            guard input.path != output.path else {
                throw DTSError.invalidArgument("DTS:X input and output paths must differ")
            }
            let loaded = try loadAndRenderDTS714(path: arguments[1])
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: loaded.master.framesPerSecond,
                override: parsed.frameRate,
                sourceDescription: "Atmos master (\(loaded.master.version))"
            )
            let qualifiedConfiguration = DTSXHDMAEncoderConfiguration(
                deliveryMode: mode,
                sourceDirectory: URL(fileURLWithPath: arguments[3]),
                referenceDirectory: URL(fileURLWithPath: arguments[4])
            )
            try qualifiedConfiguration.validateReferenceFrameRate(frameRate)
            let report = try DTSXNativeHDMAEncoder().encode(
                source: loaded.rendered,
                to: output,
                frameRate: frameRate,
                progress: makeEncodingProgressReporter()
            )
            print(try jsonString(report))

        case "encode-dtsx-source":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard arguments.count == 4 else {
                throw DTSError.invalidArgument(
                    "encode-dtsx-source requires MODE SOURCE_DTSX_DIRECTORY OUTPUT.dtshd DTSX_REFERENCE_DIRECTORY --frame-rate VALUE"
                )
            }
            let mode = try DTSXDeliveryMode(option: arguments[0])
            let sourceDirectory = URL(fileURLWithPath: arguments[1])
            let output = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            let referenceDirectory = URL(fileURLWithPath: arguments[3])
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: nil,
                override: parsed.frameRate,
                sourceDescription: "DTS:X source-directory PCM"
            )
            let encoder = DTSXHDMAEncoder(
                configuration: DTSXHDMAEncoderConfiguration(
                    deliveryMode: mode,
                    sourceDirectory: sourceDirectory,
                    referenceDirectory: referenceDirectory
                )
            )
            let report = try encoder.encode(
                sourceDirectory: sourceDirectory,
                to: output,
                frameRate: frameRate,
                progress: makeEncodingProgressReporter()
            )
            print(try jsonString(report))

        case "encode-dtsx-set":
            let parsed = try parseFrameRateOption(values)
            let arguments = parsed.arguments
            guard arguments.count == 4 else {
                throw DTSError.invalidArgument(
                    "encode-dtsx-set requires INPUT.atmos|ADM.wav|IAB.mxf OUTPUT_DIRECTORY SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY [--frame-rate VALUE]"
                )
            }
            let input = URL(fileURLWithPath: arguments[0]).standardizedFileURL
            let outputDirectory = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let sourceDirectory = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            let referenceDirectory = URL(fileURLWithPath: arguments[3]).standardizedFileURL
            let loaded = try loadAndRenderDTS714(path: arguments[0])
            let frameRate = try DTSFrameRate.resolve(
                metadataFramesPerSecond: loaded.master.framesPerSecond,
                override: parsed.frameRate,
                sourceDescription: "Atmos master (\(loaded.master.version))"
            )
            do {
                try FileManager.default.createDirectory(
                    at: outputDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw DTSError.io(
                    "cannot create DTS:X output directory \(outputDirectory.path): \(error.localizedDescription)"
                )
            }

            var artifacts: [DTSXNativeFileEncodingReport] = []
            artifacts.reserveCapacity(DTSXDeliveryMode.allCases.count)
            var committedOutputs: [URL] = []
            var batchCommitted = false
            let progress = makeEncodingProgressReporter()
            let progressTotal = 3_100
            progress(0, progressTotal)
            defer {
                // A batch is one product. If a later delivery mode fails its
                // provenance or structure gate, remove earlier outputs so a
                // caller cannot mistake a partial set for a successful encode.
                if !batchCommitted {
                    for output in committedOutputs {
                        try? FileManager.default.removeItem(at: output)
                    }
                }
            }
            for (modeIndex, mode) in DTSXDeliveryMode.allCases.enumerated() {
                let stem = input.deletingPathExtension().lastPathComponent
                let output = outputDirectory.appendingPathComponent(
                    "\(stem)-\(mode.rawValue).dtshd"
                )
                guard input.path != output.path else {
                    throw DTSError.invalidArgument("DTS:X input and output paths must differ")
                }
                guard !FileManager.default.fileExists(atPath: output.path) else {
                    throw DTSError.invalidArgument("DTS:X output already exists: \(output.path)")
                }
                let qualifiedConfiguration = DTSXHDMAEncoderConfiguration(
                    deliveryMode: mode,
                    sourceDirectory: sourceDirectory,
                    referenceDirectory: referenceDirectory
                )
                try qualifiedConfiguration.validateReferenceFrameRate(frameRate)
                let report = try DTSXNativeHDMAEncoder().encode(
                    source: loaded.rendered,
                    to: output,
                    frameRate: frameRate,
                    progress: { completed, total in
                        progress(
                            modeIndex * 1_000 + 1_000 * completed / max(1, total),
                            progressTotal
                        )
                    }
                )
                artifacts.append(report)
                committedOutputs.append(output)
            }
            let report = DTSXBatchEncodingReport(
                inputPath: input.path,
                outputDirectory: outputDirectory.path,
                artifacts: artifacts,
                allVerified: artifacts.count == DTSXDeliveryMode.allCases.count
                    && artifacts.allSatisfy(\.isVerified)
            )
            print(try jsonString(report))
            guard report.allVerified else {
                throw DTSError.malformed("DTS:X batch output failed byte/SHA/structure verification")
            }
            batchCommitted = true
            progress(progressTotal, progressTotal)

        case "qualify-dtsx":
            guard values.count == 4 else {
                throw DTSError.invalidArgument(
                    "qualify-dtsx requires MODE INPUT.atmos|ADM.wav|IAB.mxf SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY"
                )
            }
            let mode = try DTSXDeliveryMode(option: values[0])
            let master = try readAtmosMaster(values[1])
            let plan = try DTSXEncodingPlan(
                deliveryMode: mode,
                inputPath: values[1],
                sampleRate: master.audioFormat.sampleRate,
                bitDepth: master.audioFormat.bitDepth,
                sampleCount: master.audioFormat.sampleCount,
                bedChannelCount: master.bedChannels.count,
                objectCount: master.objects.count
            )
            let rendered = try renderDTS714(path: values[1])
            let sourceDirectory = URL(fileURLWithPath: values[2])
            let report = DTSXQualificationReport(
                deliveryMode: mode,
                inputPath: URL(fileURLWithPath: values[1]).standardizedFileURL.path,
                encodingPlan: plan,
                sourceSet: try DTS714SourceSet.inspect(directory: sourceDirectory),
                renderedPCM: try DTS714ReferenceComparator.compare(
                    rendered: rendered,
                    referenceDirectory: sourceDirectory
                ),
                referenceSet: try DTSXReferenceSet.inspect(
                    directory: URL(fileURLWithPath: values[3])
                )
            )
            print(try jsonString(report))
            guard report.isQualifiedForDTSXEmission else {
                throw DTSError.malformed("DTS:X qualification is not closed; no DTS:X output was written")
            }

        case "dtsx-plan":
            guard values.count == 2 else {
                throw DTSError.invalidArgument(
                    "dtsx-plan requires --blue-ray-disc|-bd|--digital-delivery|--digtal-delivery|-dd|--scsa|-scsa INPUT.atmos|ADM.wav|IAB.mxf"
                )
            }
            let mode = try DTSXDeliveryMode(option: values[0])
            let input = URL(fileURLWithPath: values[1])
            let master: AtmosMaster
            if input.pathExtension.lowercased() == "mxf" {
                master = try IMFIABReader.read(url: input).master
            } else {
                master = try readAtmosMaster(values[1])
            }
            print(try jsonString(DTSXEncodingPlan(
                deliveryMode: mode,
                inputPath: input.standardizedFileURL.path,
                sampleRate: master.audioFormat.sampleRate,
                bitDepth: master.audioFormat.bitDepth,
                sampleCount: master.audioFormat.sampleCount,
                bedChannelCount: master.bedChannels.count,
                objectCount: master.objects.count
            )))

        case "inspect-dtsx-authoring-profile":
            guard values.isEmpty else {
                throw DTSError.invalidArgument("inspect-dtsx-authoring-profile does not accept arguments")
            }
            print(try jsonString(DTS714AuthoringProfile.official.validated()))

        case "generate-dtsx-oracle-vectors":
            guard values.count == 1 else {
                throw DTSError.invalidArgument(
                    "generate-dtsx-oracle-vectors requires OUTPUT_DIRECTORY"
                )
            }
            print(try jsonString(DTSXOracleVectorGenerator.generate(
                outputDirectory: URL(fileURLWithPath: values[0])
            )))

        case "debug-dtsx-gains":
            guard values.count == 3,
                  let x = Double(values[0]),
                  let y = Double(values[1]),
                  let z = Double(values[2]) else {
                throw DTSError.invalidArgument("debug-dtsx-gains requires X Y Z")
            }
            let gains = DTS714VBAPPanner.diagnosticGains(x: x, y: y, z: z)
            let report = Dictionary(uniqueKeysWithValues: zip(
                DTS714Channel.allCases.map(\.rawValue),
                gains
            ))
            print(try jsonString(report))

        case "excerpt":
            guard values.count == 3, let count = Int(values[2]) else {
                throw DTSError.invalidArgument("excerpt requires INPUT.dts OUTPUT.dts ACCESS_UNIT_COUNT")
            }
            let infos = try DTSStreamInspector().excerpt(
                input: URL(fileURLWithPath: values[0]),
                output: URL(fileURLWithPath: values[1]),
                accessUnitCount: count
            )
            print("wrote \(infos.count) access units, \(infos.reduce(0) { $0 + $1.byteCount }) bytes")

        case "extract-container":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("extract-container requires INPUT.m2ts|mkv OUTPUT.dts")
            }
            let report = try DTSContainerExtractor.extract(
                input: URL(fileURLWithPath: values[0]),
                output: URL(fileURLWithPath: values[1])
            )
            print(try jsonString(report))

        case "extract-xllx":
            guard values.count == 3 else {
                throw DTSError.invalidArgument("extract-xllx requires INPUT.dts OUTPUT.xllx OUTPUT.json")
            }
            let report = try DTSXObjectExtractor.extract(
                inputURL: URL(fileURLWithPath: values[0]),
                payloadOutputURL: URL(fileURLWithPath: values[1]),
                indexOutputURL: URL(fileURLWithPath: values[2])
            )
            print(try jsonString(report.summary))

        case "verify-xllx-private-ast":
            guard values.count == 2 else {
                throw DTSError.invalidArgument(
                    "verify-xllx-private-ast requires INPUT_INDEX.json INPUT.xllx"
                )
            }
            let report = try DTSXPrivateASTVerifier.verify(
                indexURL: URL(fileURLWithPath: values[0]),
                payloadURL: URL(fileURLWithPath: values[1])
            )
            print(try jsonString(report))
            guard report.allFramesRoundTripExactly else {
                throw DTSError.malformed(
                    "XLL-X private AST failed byte-exact round-trip or header CRC verification"
                )
            }

        case "correlate-xllx-pcm":
            guard values.count == 4 else {
                throw DTSError.invalidArgument(
                    "correlate-xllx-pcm requires INPUT_INDEX.json INPUT.xllx SOURCE_DTSX_DIRECTORY OUTPUT.json"
                )
            }
            let outputURL = URL(fileURLWithPath: values[3])
            let report = try DTSXPrivatePCMCorrelator.analyze(
                indexURL: URL(fileURLWithPath: values[0]),
                payloadURL: URL(fileURLWithPath: values[1]),
                sourceDirectory: URL(fileURLWithPath: values[2]),
                outputURL: outputURL
            )
            let correlations = Dictionary(uniqueKeysWithValues: report.correlations.map {
                ("\($0.leftMetric)-to-\($0.rightMetric)", String($0.pearsonCorrelation))
            })
            let summary: [String: String] = [
                "frameCount": String(report.frameCount),
                "outputPath": outputURL.standardizedFileURL.path,
                "payloadSHA256": report.payloadSHA256,
                "sourcePCM_SHA256": report.sourcePCM_SHA256,
                "leadingPrimingSampleCount": String(report.leadingPrimingSampleCount),
                "trailingPaddingSampleCount": String(report.trailingPaddingSampleCount),
                "timelineIsExactlyCovered": String(report.timelineIsExactlyCovered),
                "strongestHeightRiceLagFrames": String(report.strongestHeightRiceLagFrames),
                "heightRiceToPayloadBitRSquared": String(
                    report.heightRiceToPayloadBitRegression.rSquared
                ),
                "correlations": try jsonString(correlations)
            ]
            print(try jsonString(summary))

        case "analyze-xllx-body-fields":
            guard values.count == 4 else {
                throw DTSError.invalidArgument(
                    "analyze-xllx-body-fields requires INPUT_INDEX.json INPUT.xllx CORRELATION.json OUTPUT.json"
                )
            }
            let outputURL = URL(fileURLWithPath: values[3])
            let report = try DTSXPrivateBodyFieldAnalyzer.analyze(
                indexURL: URL(fileURLWithPath: values[0]),
                payloadURL: URL(fileURLWithPath: values[1]),
                correlationURL: URL(fileURLWithPath: values[2]),
                outputURL: outputURL
            )
            let best = report.candidates.first
            let bestCompact = report.compactCandidates.first
            let summary: [String: String] = [
                "frameCount": String(report.frameCount),
                "outputPath": report.outputPath,
                "payloadSHA256": report.payloadSHA256,
                "candidateCount": String(report.candidates.count),
                "compactCandidateCount": String(report.compactCandidates.count),
                "bestCandidateBitOffset": String(best?.bitOffset ?? -1),
                "bestCandidateBitWidth": String(best?.bitWidth ?? 0),
                "bestCandidateMutualInformationBits": String(
                    best?.activeMaskMutualInformationBits ?? 0
                ),
                "bestCandidateSingleChannelAccuracy": String(
                    best?.singleChannelClassificationAccuracy ?? 0
                ),
                "bestCompactCandidateBitOffset": String(bestCompact?.bitOffset ?? -1),
                "bestCompactCandidateBitWidth": String(bestCompact?.bitWidth ?? 0),
                "singleHeightChannelSampleCount": String(
                    report.singleHeightChannelPrefixRelation.sampleCount
                ),
                "singleHeightChannelPrefixRelationExact": String(
                    report.singleHeightChannelPrefixRelation.relationHoldsForEverySample
                ),
                "predictionHeaderEligibleFrameCount": String(
                    report.predictionHeaderCandidate.eligibleFrameCount
                ),
                "predictionHeaderRelationExact": String(
                    report.predictionHeaderCandidate.relationHoldsForEveryEligibleFrame
                ),
                "predictionCandidateImprovesRawFrameCount": String(
                    report.predictionHeaderCandidate.candidatePredictionImprovesRawRiceFrameCount
                ),
                "predictionCandidateToRawRiceRatio": String(
                    report.predictionHeaderCandidate.meanCandidateToRawRiceBitRatio
                ),
                "isolatedEntropyDecodedFrameCount": String(
                    report.predictionHeaderCandidate.isolatedEntropyDecodedFrameCount
                ),
                "isolatedEntropySampleExactFrameCount": String(
                    report.predictionHeaderCandidate.isolatedEntropySampleExactFrameCount
                )
            ]
            print(try jsonString(summary))

        case "analyze-xllx-generic-decode":
            guard values.count == 4 else {
                throw DTSError.invalidArgument(
                    "analyze-xllx-generic-decode requires INPUT_INDEX.json INPUT.xllx SOURCE_DTSX_DIRECTORY OUTPUT.json"
                )
            }
            let outputURL = URL(fileURLWithPath: values[3])
            let report = try DTSXPrivateGenericDecodeAnalyzer.analyze(
                indexURL: URL(fileURLWithPath: values[0]),
                payloadURL: URL(fileURLWithPath: values[1]),
                sourceDirectory: URL(fileURLWithPath: values[2]),
                outputURL: outputURL
            )
            let summary: [String: String] = [
                "frameCount": String(report.frameCount),
                "candidateHeaderParsedFrameCount": String(
                    report.candidateHeaderParsedFrameCount
                ),
                "genericProfileEligibleFrameCount": String(
                    report.genericProfileEligibleFrameCount
                ),
                "entropyDecodedFrameCount": String(report.entropyDecodedFrameCount),
                "decodedFrameTrailingBitsAllZeroCount": String(
                    report.decodedFrameTrailingBitsAllZeroCount
                ),
                "sampleExactFrameTrailingBitsAllZeroCount": String(
                    report.sampleExactFrameTrailingBitsAllZeroCount
                ),
                "fullPermutationExactFrameCount": String(
                    report.fullPermutationExactFrameCount
                ),
                "secondaryPermutationValidFrameCount": String(
                    report.secondaryPermutationValidFrameCount
                ),
                "secondaryPermutationBestScoreFrameCount": String(
                    report.secondaryPermutationBestScoreFrameCount
                ),
                "secondaryPermutationSampleExactFrameCount": String(
                    report.secondaryPermutationSampleExactFrameCount
                ),
                "partialPermutationOver1000SampleFrameCount": String(
                    report.partialPermutationOver1000SampleFrameCount
                ),
                "prefixSweepAnySampleExactFrameCount": String(
                    report.prefixSweepAnySampleExactFrameCount
                ),
                "prefixSweepUniqueSampleExactFrameCount": String(
                    report.prefixSweepUniqueSampleExactFrameCount
                ),
                "prefixSweepAmbiguousSampleExactFrameCount": String(
                    report.prefixSweepAmbiguousSampleExactFrameCount
                ),
                "prefixSweepAdditionalSampleExactFrameCount": String(
                    report.prefixSweepAdditionalSampleExactFrameCount
                ),
                "autodetectedBranchZeroFrameCount": String(
                    report.autodetectedBranchZeroFrameCount
                ),
                "autodetectedBranchZeroSampleExactFrameCount": String(
                    report.autodetectedBranchZeroSampleExactFrameCount
                ),
                "autodetectedBranchZeroSampleMismatchFrameCount": String(
                    report.autodetectedBranchZeroSampleMismatchFrameCount
                ),
                "genericDecoderIsClosed": String(report.genericDecoderIsClosed),
                "outputPath": outputURL.standardizedFileURL.path
            ]
            print(try jsonString(summary))

        case "survey-xllx":
            guard values.count == 3 else {
                throw DTSError.invalidArgument("survey-xllx requires INPUT.json INPUT.xllx OUTPUT.json")
            }
            let report = try DTSXPrivateSyntaxSurvey.analyze(
                indexURL: URL(fileURLWithPath: values[0]),
                payloadURL: URL(fileURLWithPath: values[1]),
                outputURL: URL(fileURLWithPath: values[2])
            )
            print(try jsonString([
                "frameCount": String(report.frameCount),
                "uniquePayloadCount": String(report.uniquePayloadCount),
                "commonPrefixByteCount": String(report.commonPrefixByteCount),
                "fixedPreambleAfterSyncHex": report.fixedPreambleAfterSyncHex ?? "",
                "crc16ZeroPrefixByteCounts": report.crc16ZeroPrefixByteCounts.map(String.init).joined(separator: ","),
                "lengthFieldCandidateCount": String(report.lengthFieldCandidates.count)
            ]))

        case "compare-xllx":
            guard values.count == 5 else {
                throw DTSError.invalidArgument(
                    "compare-xllx requires BASE.json BASE.xllx VARIANT.json VARIANT.xllx OUTPUT.json"
                )
            }
            let report = try DTSXPrivateDifferential.compare(
                baselineIndexURL: URL(fileURLWithPath: values[0]),
                baselinePayloadURL: URL(fileURLWithPath: values[1]),
                variantIndexURL: URL(fileURLWithPath: values[2]),
                variantPayloadURL: URL(fileURLWithPath: values[3]),
                outputURL: URL(fileURLWithPath: values[4])
            )
            print(try jsonString(report.summary))

        case "verify-xllx-routing-remap":
            guard values.count == 6 else {
                throw DTSError.invalidArgument(
                    "verify-xllx-routing-remap requires BASE.json BASE.xllx VARIANT.json VARIANT.xllx OLD_TO_NEW OUTPUT.json"
                )
            }
            let heightMap = values[4].split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
            guard heightMap.count == 4 else {
                throw DTSError.invalidArgument(
                    "OLD_TO_NEW must contain four comma-separated height indices"
                )
            }
            let report = try DTSXPrivateControlledRoutingVerifier.verify(
                baselineIndexURL: URL(fileURLWithPath: values[0]),
                baselinePayloadURL: URL(fileURLWithPath: values[1]),
                variantIndexURL: URL(fileURLWithPath: values[2]),
                variantPayloadURL: URL(fileURLWithPath: values[3]),
                oldToNewHeightMap: heightMap,
                outputURL: URL(fileURLWithPath: values[5])
            )
            print(try jsonString(report))
            guard report.isVerified else {
                throw DTSError.malformed(
                    "XLL-X controlled routing remap is not byte-exact"
                )
            }

        case "analyze-xllx-controlled-pair":
            guard values.count == 5 else {
                throw DTSError.invalidArgument(
                    "analyze-xllx-controlled-pair requires BASE.json BASE.xllx VARIANT.json VARIANT.xllx OUTPUT.json"
                )
            }
            let report = try DTSXPrivateControlledPairAnalyzer.analyze(
                baselineIndexURL: URL(fileURLWithPath: values[0]),
                baselinePayloadURL: URL(fileURLWithPath: values[1]),
                variantIndexURL: URL(fileURLWithPath: values[2]),
                variantPayloadURL: URL(fileURLWithPath: values[3]),
                outputURL: URL(fileURLWithPath: values[4])
            )
            print(try jsonString([
                "frameCount": String(report.frameCount),
                "changedFrameCount": String(report.changedFrameCount),
                "baselineDecodedFrameCount": String(report.baselineDecodedFrameCount),
                "variantDecodedFrameCount": String(report.variantDecodedFrameCount),
                "lfhDirectMatchFrameCount": String(report.lfhDirectMatchFrameCount),
                "lfhBestTransformExactFrameCount": String(
                    report.lfhBestTransformExactFrameCount
                ),
                "outputPath": URL(fileURLWithPath: values[4]).standardizedFileURL.path
            ]))

        case "verify-xllx-controlled-pcm":
            guard values.count == 4 else {
                throw DTSError.invalidArgument(
                    "verify-xllx-controlled-pcm requires ALL_MUTE.dtshd LFH_ONLY.dtshd LFH_RFH.dtshd OUTPUT.json"
                )
            }
            let report = try DTSXPrivateControlledPCMVerifier.verify(
                allMuteURL: URL(fileURLWithPath: values[0]),
                lfhOnlyURL: URL(fileURLWithPath: values[1]),
                lfhRfhURL: URL(fileURLWithPath: values[2]),
                outputURL: URL(fileURLWithPath: values[3])
            )
            print(try jsonString(report))
            guard report.isBitExact else {
                throw DTSError.malformed(
                    "XLL-X controlled PCM difference is not sample-exact"
                )
            }

        case "inspect-xllx-private-frame":
            guard values.count == 4, let frameIndex = Int(values[2]) else {
                throw DTSError.invalidArgument(
                    "inspect-xllx-private-frame requires INPUT.json INPUT.xllx FRAME_INDEX OUTPUT.json"
                )
            }
            let report = try DTSXPrivateFrameInspector.inspect(
                indexURL: URL(fileURLWithPath: values[0]),
                payloadURL: URL(fileURLWithPath: values[1]),
                frameIndex: frameIndex,
                outputURL: URL(fileURLWithPath: values[3])
            )
            print(try jsonString(report))

        case "decode-dlc":
            guard values.count == 3, let frameRateCode = Int(values[1]) else {
                throw DTSError.invalidArgument("decode-dlc requires INPUT.bin FRAME_RATE_CODE OUTPUT.json")
            }
            let payload: Data
            do { payload = try Data(contentsOf: URL(fileURLWithPath: values[0])) } catch {
                throw DTSError.io("cannot read \(values[0]): \(error.localizedDescription)")
            }
            let sampleCount = try IMFIABReader.frameSampleCount(frameRateCode: frameRateCode)
            let samples = try IABDLCDecoder.decode(
                bytes: Array(payload),
                byteOffset: 0,
                byteLimit: payload.count,
                sampleCount: sampleCount,
                frameRateCode: frameRateCode
            )
            let encoded = try JSONEncoder().encode(samples)
            do { try encoded.write(to: URL(fileURLWithPath: values[2]), options: .atomic) } catch {
                throw DTSError.io("cannot write \(values[2]): \(error.localizedDescription)")
            }
            print("decoded \(samples.count) DLC samples")

        case "render-atmos-7.1":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("render-atmos-7.1 requires INPUT.atmos|ADM.wav|IAB.mxf OUTPUT_7.1.wav")
            }
            throw DTSError.unsupported(
                "Atmos input is reserved for DTS:X 7.1.4 output; ordinary 7.1 rendering is disabled"
            )

        case "render-atmos-7.1.4":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("render-atmos-7.1.4 requires INPUT.atmos|ADM.wav|IAB.mxf OUTPUT_DIRECTORY")
            }
            let rendered = try renderDTS714(path: values[0])
            let output = URL(fileURLWithPath: values[1])
            try DTS714Renderer.writeMonoWaves(rendered, to: output)
            print("rendered \(rendered.sampleCount) samples to 12 DTS:X 7.1.4 mono WAVE files")

        case "compare-atmos-7.1.4":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("compare-atmos-7.1.4 requires INPUT.atmos|ADM.wav|IAB.mxf REFERENCE_DIRECTORY")
            }
            let rendered = try renderDTS714(path: values[0])
            let comparison = try DTS714ReferenceComparator.compare(
                rendered: rendered,
                referenceDirectory: URL(fileURLWithPath: values[1])
            )
            print(try jsonString(comparison))
            if !comparison.isBitExact {
                throw DTSError.malformed("Atmos-to-DTS:X 7.1.4 PCM comparison is not bit-exact")
            }

        case "compare-dtsx714-waves":
            guard values.count == 2 else {
                throw DTSError.invalidArgument("compare-dtsx714-waves requires RENDERED_DIRECTORY SOURCE_DTSX_DIRECTORY")
            }
            let comparison = try DTS714ReferenceComparator.compare(
                renderedDirectory: URL(fileURLWithPath: values[0]),
                referenceDirectory: URL(fileURLWithPath: values[1])
            )
            print(try jsonString(comparison))
            if !comparison.isBitExact {
                throw DTSError.malformed("DTS:X 7.1.4 PCM comparison is not bit-exact")
            }

        case "inspect-atmos":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("inspect-atmos requires INPUT.atmos")
            }
            let master = try readAtmosMaster(values[0])
            print(try jsonString(AtmosMasterSummary(master: master)))

        case "hash-atmos-pcm":
            guard values.count == 1 else {
                throw DTSError.invalidArgument("hash-atmos-pcm requires INPUT.atmos|ADM.wav")
            }
            let master = try readAtmosMaster(values[0])
            print(try SHA256Hasher.hash(
                fileAt: master.audioURL,
                byteOffset: master.audioFormat.audioDataOffset,
                byteCount: master.audioFormat.audioDataByteCount
            ))

        case "compare-atmos-metadata":
            guard values.count == 2 else {
                throw DTSError.invalidArgument(
                    "compare-atmos-metadata requires BASE.atmos|ADM.wav VARIANT.atmos|ADM.wav"
                )
            }
            let report = try AtmosMasterComparator.compare(
                baseline: readAtmosMaster(values[0]),
                variant: readAtmosMaster(values[1])
            )
            print(try jsonString(report))

        case "inspect-atmos-block":
            let requestedSampleCount = values.count == 3 ? Int(values[2]) : 512
            guard (2...3).contains(values.count),
                  let sampleStart = Int64(values[1]),
                  let sampleCount = requestedSampleCount else {
                throw DTSError.invalidArgument("inspect-atmos-block requires INPUT.atmos SAMPLE_START [SAMPLE_COUNT]")
            }
            let master = try readAtmosMaster(values[0])
            let block = try AtmosSceneReader.readBlock(
                master: master,
                sampleStart: sampleStart,
                sampleCount: sampleCount
            )
            print(try jsonString(AtmosSceneBlockSummary(master: master, block: block)))

        case "help", "--help", "-h":
            printUsage()
        default:
            throw DTSError.invalidArgument("unknown command \(command)")
        }
#else
        if command == "help" || command == "--help" || command == "-h" {
            printUsage()
            return
        }
        throw DTSError.invalidArgument(
            "\(command) is a Debug-only diagnostic command; Release accepts -i INPUT -o OUTPUT [--frame-rate VALUE]"
        )
#endif
    }

    private static func readAtmosMaster(_ path: String) throws -> AtmosMaster {
        try AtmosInputReader.read(url: URL(fileURLWithPath: path))
    }

    private static func loadAndRenderDTS714(
        path: String,
        maximumSourceFrameCount: Int? = nil
    ) throws -> LoadedDTS714Source {
        let input = try AtmosInputReader.resolve(url: URL(fileURLWithPath: path))
        let maximumSampleCount: Int?
        if let maximumSourceFrameCount {
            let (value, overflow) = maximumSourceFrameCount.multipliedReportingOverflow(
                by: DTSXPrivateFrameEncoder.frameSampleCount
            )
            guard !overflow else {
                throw DTSError.valueOutOfRange(
                    field: "maximum DTS:X render sample count",
                    value: String(maximumSourceFrameCount)
                )
            }
            maximumSampleCount = value
        } else {
            maximumSampleCount = nil
        }
        if input.pathExtension.lowercased() == "mxf" {
            let iab = try IMFIABReader.read(url: input)
            return LoadedDTS714Source(
                master: iab.master,
                rendered: try DTS714Renderer.render(
                    iab: iab,
                    maximumSampleCount: maximumSampleCount
                )
            )
        }
        let master = try AtmosInputReader.read(url: input)
        return LoadedDTS714Source(
            master: master,
            rendered: try DTS714Renderer.render(
                master: master,
                maximumSampleCount: maximumSampleCount
            )
        )
    }

    private static func renderDTS714(
        path: String,
        maximumSourceFrameCount: Int? = nil
    ) throws -> DTS714PCMBuffer {
        try loadAndRenderDTS714(
            path: path,
            maximumSourceFrameCount: maximumSourceFrameCount
        ).rendered
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Terminal progress renderer, modelled after the ProRes encoder's
    /// serialized 40-cell terminal bar. stderr keeps machine-readable reports
    /// on stdout free of terminal control characters.
    private final class EncodingProgressBar: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -1
        private var hasFinished = false

        func update(completed: Int, total: Int) {
            guard total > 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !hasFinished else { return }

            let percent = min(100, max(0, completed * 100 / total))
            guard percent != lastPercent else { return }
            lastPercent = percent
            render(percent: percent)
            if percent == 100 {
                hasFinished = true
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }

        private func render(percent: Int) {
            let width = 40
            let filled = percent * width / 100
            let bar = String(repeating: "█", count: filled)
                + String(repeating: "░", count: width - filled)
            FileHandle.standardError.write(
                Data("\r  Encoding [\(bar)] \(percent)%".utf8)
            )
        }
    }
    private static func makeEncodingProgressReporter() -> (Int, Int) -> Void {
        let progress = EncodingProgressBar()
        return { completed, total in
            progress.update(completed: completed, total: total)
        }
    }

    private static func parseFrameRateOption(
        _ arguments: [String]
    ) throws -> (arguments: [String], frameRate: DTSFrameRate?) {
        var remaining: [String] = []
        var frameRate: DTSFrameRate?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--frame-rate" {
                guard frameRate == nil else {
                    throw DTSError.invalidArgument("--frame-rate may be specified only once")
                }
                guard index + 1 < arguments.count else {
                    throw DTSError.invalidArgument("--frame-rate requires a value")
                }
                frameRate = try DTSFrameRate(argument: arguments[index + 1])
                index += 2
            } else {
                remaining.append(arguments[index])
                index += 1
            }
        }
        return (remaining, frameRate)
    }

    private static func parseAutomaticOptions(
        _ arguments: [String]
    ) throws -> (input: URL, output: URL, frameRate: DTSFrameRate?) {
        var input: URL?
        var output: URL?
        var frameRate: DTSFrameRate?
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard option == "-i" || option == "-o" || option == "--frame-rate" else {
                throw DTSError.invalidArgument(
                    "unknown option \(option); use -i INPUT -o OUTPUT [--frame-rate VALUE]"
                )
            }
            guard index + 1 < arguments.count else {
                throw DTSError.invalidArgument("\(option) requires a value")
            }
            if option == "--frame-rate" {
                guard frameRate == nil else {
                    throw DTSError.invalidArgument("--frame-rate may be specified only once")
                }
                frameRate = try DTSFrameRate(argument: arguments[index + 1])
                index += 2
                continue
            }
            let value = URL(fileURLWithPath: arguments[index + 1])
            if option == "-i" {
                guard input == nil else { throw DTSError.invalidArgument("-i may be specified only once") }
                input = value
            } else {
                guard output == nil else { throw DTSError.invalidArgument("-o may be specified only once") }
                output = value
            }
            index += 2
        }
        guard let input, let output else {
            throw DTSError.invalidArgument("automatic encoding requires -i INPUT -o OUTPUT")
        }
        guard output.pathExtension.lowercased() == "dtshd" else {
            throw DTSError.invalidArgument("automatic product output must use the .dtshd extension")
        }
        return (input, output, frameRate)
    }

    private static func productOutputURL(_ path: String) throws -> URL {
        let output = URL(fileURLWithPath: path).standardizedFileURL
        guard output.pathExtension.lowercased() == "dtshd" else {
            throw DTSError.invalidArgument("DTS HDMA product output must use the .dtshd extension")
        }
        return output
    }

    private static func printUsage() {
        var usage = """
        Native Swift 6 DTS HDMA / DTS:X HDMA research encoder

        Primary usage:
          hdmax -i INPUT_5.1.wav|INPUT_7.1.wav|INPUT.atmos|ADM.wav|IAB.mxf -o OUTPUT.dtshd [--frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60]

        Automatic mapping:
          5.1 WAVE                    -> DTS HDMA
          7.1 WAVE                    -> DTS HDMA
          DAMF / ADM BWF / IMF IAB    -> DTS:X HDMA from rendered 7.1.4

        Automatic delivery sidecars:
          OUTPUT.dtspbr
          OUTPUT.dtshd_log.txt

        Frame-rate handling:
          DAMF / IMF IAB metadata is used automatically. ADM BWF and ordinary
          PCM WAVE inputs require --frame-rate when no authoring rate is stored.
          A supplied override must match any rate present in the master.
          Supported values are 23.976, 24, 47.952, 25, 29.97, 30, 48, 50,
          59.94, and 60; all are non-drop SMPTE timebases.

        Atmos inputs are rendered by the native 7.1.4 renderer, then encoded
        as Core + scalable XLL compatibility bed + four-height XLL-X. The
        current private profile preserves rendered height PCM but not separate
        object IDs or trajectories.

        """

#if DEBUG
        usage += """
        Diagnostic commands:
        Usage:
          hdmax encode-xll INPUT.wav OUTPUT.dts
          hdmax encode-core INPUT.wav OUTPUT.dts
          hdmax extract-core INPUT.dtshd OUTPUT.dts
          hdmax verify-core-syntax INPUT.dts|INPUT.dtshd
          hdmax decode-core INPUT.dts|INPUT.dtshd OUTPUT.wav
          hdmax verify-core-pcm INPUT.dts|INPUT.dtshd ORACLE_32BIT.wav
          hdmax analyze-core-quality SOURCE_5.1.wav INPUT.dts|INPUT.dtshd [ALIGNMENT_SAMPLES]
          hdmax encode-hdma INPUT_5.1.wav|INPUT_7.1.wav OUTPUT.dtshd --frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60
          hdmax encode-hdma-source SOURCE_HDMA_DIRECTORY OUTPUT.dtshd [FRAME_COUNT] --frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60
          hdmax decode-xll INPUT.dts OUTPUT.wav
          hdmax verify-hdma INPUT.wav OUTPUT.dtshd [OUTPUT_DECODED.wav] --frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60
          hdmax hash-pcm INPUT.wav
          hdmax sha256 INPUT
          hdmax md5 INPUT
          hdmax generate stereo|5.1|7.1 FRAME_COUNT OUTPUT.wav
          hdmax compare EXPECTED.wav ACTUAL.wav
          hdmax compare-padded EXPECTED.wav PADDED_ACTUAL.wav
          hdmax render-7.1-to-5.1 INPUT.wav OUTPUT.wav
          hdmax render-atmos-7.1.4 INPUT.atmos|ADM.wav|IAB.mxf OUTPUT_DIRECTORY
          hdmax compare-atmos-7.1.4 INPUT.atmos|ADM.wav|IAB.mxf SOURCE_DTSX_DIRECTORY
          hdmax compare-dtsx714-waves RENDERED_DIRECTORY SOURCE_DTSX_DIRECTORY
          hdmax dtsx-plan --blue-ray-disc|-bd|--digital-delivery|--digtal-delivery|-dd|--scsa|-scsa INPUT.atmos|ADM.wav|IAB.mxf
          hdmax inspect-dtsx-authoring-profile
          hdmax generate-dtsx-oracle-vectors OUTPUT_DIRECTORY
          hdmax debug-dtsx-gains X Y Z
          hdmax inspect-dtsx-reference DTSX_REFERENCE_DIRECTORY
          hdmax verify-dtsx-reference-set DTSX_REFERENCE_DIRECTORY
          hdmax verify-dtsx-output-set OUTPUT_DIRECTORY SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY
          hdmax verify-hdma-reference-set HDMA_REFERENCE_DIRECTORY SOURCE_HDMA_DIRECTORY
          hdmax inspect-dtsx-source SOURCE_DTSX_DIRECTORY
          hdmax verify-dtsx INPUT.dtshd [EXPECTED.dtshd]
          hdmax verify-official-ast INPUT.dtshd
          hdmax verify-xll-pbr INPUT.dtshd
          hdmax verify-xll-channel-set-pcm INPUT.dtshd CHANNEL_SET_INDEX EXPECTED_CHANNEL_0.wav EXPECTED_CHANNEL_1.wav [...]
          hdmax inspect-xll-frame-decode INPUT.dtshd FRAME_INDEX
          hdmax verify-xll-decode INPUT.dtshd
          hdmax verify-xll-core-oracle INPUT.dtshd CORE_ORACLE_5.1.wav SOURCE_HDMA_DIRECTORY
          hdmax verify-xll-core-native INPUT.dtshd SOURCE_HDMA_DIRECTORY
          hdmax verify-dtsx-compatibility-bed-native INPUT.dtshd SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]
          hdmax verify-dtsx-compatibility-bed-oracle INPUT.dtshd CORE_ORACLE_5.1.wav SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]
          hdmax verify-dtsx-private-heights-native INPUT.dtshd SOURCE_DTSX_DIRECTORY [SOURCE_FRAME_COUNT]
          hdmax write-dtsx-compatibility-bed-source SOURCE_DTSX_DIRECTORY OUTPUT_7.1.wav [SOURCE_FRAME_COUNT]
          hdmax verify-xllx-native-encoder
          hdmax verify-xllx-official-inverse INPUT_INDEX.json INPUT.xllx OUTPUT.json [MAX_FRAMES]
          hdmax verify-dtsx-native-encoder
          hdmax encode-dtsx-native-wave INPUT_7.1.4.wav OUTPUT.dtshd [SOURCE_FRAME_COUNT] --frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60
          hdmax encode-dtsx-native-source SOURCE_DTSX_DIRECTORY OUTPUT.dtshd [SOURCE_FRAME_COUNT] --frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60
          hdmax encode-dtsx-native INPUT.atmos|ADM.wav|IAB.mxf OUTPUT.dtshd [SOURCE_FRAME_COUNT] [--frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60]
          hdmax encode-dtsx MODE INPUT.atmos|ADM.wav|IAB.mxf OUTPUT.dtshd SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY [--frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60]
          hdmax encode-dtsx-source MODE SOURCE_DTSX_DIRECTORY OUTPUT.dtshd DTSX_REFERENCE_DIRECTORY --frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60
          hdmax encode-dtsx-set INPUT.atmos|ADM.wav|IAB.mxf OUTPUT_DIRECTORY SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY [--frame-rate 23.976|24|25|29.97|30|47.952|48|50|59.94|60]
          hdmax qualify-dtsx MODE INPUT.atmos|ADM.wav|IAB.mxf SOURCE_DTSX_DIRECTORY DTSX_REFERENCE_DIRECTORY
          hdmax decode-dlc INPUT.bin FRAME_RATE_CODE OUTPUT.json
          hdmax inspect INPUT.dts [ACCESS_UNIT_COUNT]
          hdmax analyze-dtsx INPUT.dts [OUTPUT.json]
          hdmax diff-dtshd BASELINE.dts VARIANT.dts [ACCESS_UNIT_COUNT]
          hdmax diff-dtshd-summary BASELINE.dts VARIANT.dts [ACCESS_UNIT_COUNT]
          hdmax qc-dtshd INPUT.dts [EXPECTED.dts]
          hdmax compare-dtsx-bitrate REFERENCE.dtshd CANDIDATE.dtshd [ACCESS_UNIT_COUNT]
          hdmax excerpt INPUT.dts OUTPUT.dts ACCESS_UNIT_COUNT
          hdmax extract-container INPUT.m2ts|mkv OUTPUT.dts
          hdmax extract-xllx INPUT.dts OUTPUT.xllx OUTPUT.json
          hdmax verify-xllx-private-ast INPUT_INDEX.json INPUT.xllx
          hdmax correlate-xllx-pcm INPUT_INDEX.json INPUT.xllx SOURCE_DTSX_DIRECTORY OUTPUT.json
          hdmax analyze-xllx-body-fields INPUT_INDEX.json INPUT.xllx CORRELATION.json OUTPUT.json
          hdmax analyze-xllx-generic-decode INPUT_INDEX.json INPUT.xllx SOURCE_DTSX_DIRECTORY OUTPUT.json
          hdmax survey-xllx INPUT.json INPUT.xllx OUTPUT.json
          hdmax compare-xllx BASE.json BASE.xllx VARIANT.json VARIANT.xllx OUTPUT.json
          hdmax verify-xllx-routing-remap BASE.json BASE.xllx VARIANT.json VARIANT.xllx OLD_TO_NEW OUTPUT.json
          hdmax analyze-xllx-controlled-pair BASE.json BASE.xllx VARIANT.json VARIANT.xllx OUTPUT.json
          hdmax inspect-xllx-private-frame INPUT.json INPUT.xllx FRAME_INDEX OUTPUT.json
          hdmax inspect-atmos INPUT.atmos|ADM.wav|IAB.mxf
          hdmax hash-atmos-pcm INPUT.atmos|ADM.wav
          hdmax compare-atmos-metadata BASE.atmos|ADM.wav|IAB.mxf VARIANT.atmos|ADM.wav|IAB.mxf
          hdmax inspect-atmos-block INPUT.atmos|ADM.wav SAMPLE_START [SAMPLE_COUNT]

        Constraints: 48 kHz packed 24-bit integer PCM. `encode-xll` is an
        internal XLL-standalone diagnostic and requires 512-sample alignment.
        DTS HDMA accepts 5.1(side) or 7.1 PCM only (Core folds 7.1 to 5.1, XLL
        keeps 7.1) and explicitly zero-pads the final 512-sample AU. Atmos is never
        silently rendered to 7.1 HDMA. `dtsx-plan` validates the 48 kHz/24-bit
        object-master input and fixes the 7.1.4 contract. Native Core+XLL+XLL-X
        emission is accepted only after its internal decoder and structure gates pass.
        """
#endif
        print(usage)
    }
}
