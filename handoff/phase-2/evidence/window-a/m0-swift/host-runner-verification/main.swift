import Darwin
import Foundation

@main struct Verification {
  static func main() async {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    let python = URL(fileURLWithPath: "/usr/bin/python3")
    var checks: [String: Bool] = [:]
    let sleeping = "import os,sys,time;open(sys.argv[1],'w').write(str(os.getpid()));time.sleep(60)"
    func absent(_ marker: URL) -> Bool {
      guard let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text) else {
        return false
      }
      errno = 0
      return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }
    do {
      let result = try await UTMHostProcessRunner.run(
        executable: python,
        arguments: ["-c", "import sys;print('output');print('error',file=sys.stderr);sys.exit(42)"],
        until: .now + .seconds(10))
      checks["separateOutputAndExit42"] = result.terminationStatus == 42
        && result.standardOutput == Data("output\n".utf8)
        && result.standardError == Data("error\n".utf8)
    } catch { checks["separateOutputAndExit42"] = false }
    let expired = directory.appendingPathComponent("expired-pid.txt")
    do {
      _ = try await UTMHostProcessRunner.run(
        executable: python, arguments: ["-c", sleeping, expired.path], until: .now - .seconds(1))
      checks["expiredDeadlineDidNotLaunch"] = false
    } catch UTMHostProcessError.timedOut {
      checks["expiredDeadlineDidNotLaunch"] = !FileManager.default.fileExists(atPath: expired.path)
    } catch { checks["expiredDeadlineDidNotLaunch"] = false }
    let timedOut = directory.appendingPathComponent("timeout-pid.txt")
    do {
      _ = try await UTMHostProcessRunner.run(
        executable: python, arguments: ["-c", sleeping, timedOut.path], until: .now + .seconds(1))
      checks["timeoutKilledAndReaped"] = false
    } catch UTMHostProcessError.timedOut {
      checks["timeoutKilledAndReaped"] = absent(timedOut)
    } catch { checks["timeoutKilledAndReaped"] = false }
    let cancelled = directory.appendingPathComponent("cancel-pid.txt")
    let task = Task {
      try await UTMHostProcessRunner.run(
        executable: python, arguments: ["-c", sleeping, cancelled.path], until: .now + .seconds(30))
    }
    let markerDeadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: cancelled.path), ContinuousClock.now < markerDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    task.cancel()
    do {
      _ = try await task.value
      checks["cancelKilledAndReaped"] = false
    } catch is CancellationError {
      checks["cancelKilledAndReaped"] = absent(cancelled)
    } catch { checks["cancelKilledAndReaped"] = false }
    let flooded = directory.appendingPathComponent("flood-pid.txt")
    let floodScript = "import os,sys,time;open(sys.argv[1],'w').write(str(os.getpid()));"
      + "os.write(1,b'x'*1000000);time.sleep(60)"
    do {
      _ = try await UTMHostProcessRunner.run(
        executable: python, arguments: ["-c", floodScript, flooded.path],
        until: .now + .seconds(10), maximumOutputBytes: 65536)
      checks["outputLimitKilledAndReaped"] = false
    } catch UTMHostProcessError.outputLimitExceeded {
      checks["outputLimitKilledAndReaped"] = absent(flooded)
    } catch { checks["outputLimitKilledAndReaped"] = false }
    if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted,.sortedKeys]) {
      try? data.write(to: directory.appendingPathComponent("result.json"))
      print(String(decoding: data, as: UTF8.self))
    }
    Darwin.exit(checks.values.allSatisfy { $0 } ? 0 : 1)
  }
}
