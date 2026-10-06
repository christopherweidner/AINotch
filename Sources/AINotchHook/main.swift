// SPDX-License-Identifier: GPL-3.0-or-later
//
// ainotch-hook: Claude Code runs this for each registered hook event. It
// forwards the event to AINotch and, for questions and permission prompts,
// prints the person's answer for Claude Code to act on. When AINotch is not
// running it exits immediately with no output, so Claude Code is unaffected.

import AINotchCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

signal(SIGPIPE, SIG_IGN)

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let event = payload["hook_event_name"] as? String else { exit(0) }

let message = HookMessage(event: event, payload: payload,
                          wantsReply: HookMessage.wantsReply(event: event, payload: payload))
let environment = ProcessInfo.processInfo.environment
let socketPath = environment["AINOTCH_SOCKET"] ?? AINotchPaths.socket.path
// Stay under the 3600 s timeout the installer registers for blocking hooks.
let timeout = Double(environment["AINOTCH_HOOK_TIMEOUT"] ?? "") ?? 3500

if let stdout = HookClient.send(message, socketPath: socketPath, timeout: timeout) {
    FileHandle.standardOutput.write(Data(stdout.utf8))
}
exit(0)
