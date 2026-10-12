import Foundation

// navassist-eval: offline benchmarks behind docs/technical-report.md.
//
//   swift run -c release navassist-eval tum <DepthAnythingV2SmallF16.mlmodelc> <tum sequence folder> <output folder> [frame stride]
//   swift run -c release navassist-eval simulate <output folder> [trips]

let args = CommandLine.arguments
func usage() -> Never {
    print("""
    usage:
      navassist-eval tum <model.mlmodelc> <tum sequence folder> <output folder> [frame stride, default 10]
      navassist-eval simulate <output folder> [trips, default 600]
    """)
    exit(2)
}
guard args.count >= 2 else { usage() }

do {
    switch args[1] {
    case "tum":
        guard args.count >= 5 else { usage() }
        let bench = TUMBenchmark(seq: try TUMSequence(args[3]), model: try DepthModel(compiledModel: args[2]),
                                 out: URL(fileURLWithPath: args[4]), frameStride: args.count > 5 ? Int(args[5]) ?? 10 : 10)
        try bench.run()
    case "simulate":
        guard args.count >= 3 else { usage() }
        try PredictorEvaluation(out: URL(fileURLWithPath: args[2]), trips: args.count > 3 ? Int(args[3]) ?? 600 : 600).run()
    default:
        usage()
    }
} catch {
    print("error: \(error)")
    exit(1)
}
