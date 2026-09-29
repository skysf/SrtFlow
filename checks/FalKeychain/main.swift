import Foundation

// FalKeyStore 对真的钥匙串走一遍（本机手动，不在 check-all 里）：存 → 有 → 静默读到 → 换一把 → 读到新的 → 删 → 没有。
// 用一个专门的服务名（`check.srtflow.fal.<pid>`），跑完一定删掉；同一个进程建的项自己读不弹授权框。
// 不验「别的签名读要弹框」那一半：那要两个不同签名的进程，靠 docs/architecture/fal-generation.md 的人工清单和 2026-09-29 的探针。

var failures = 0
var checks = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition { failures += 1; print("FAIL [line \(line)] \(message)") }
}

let service = "check.srtflow.fal.\(getpid())"
let first = "11111111-2222-3333-4444-555555555555:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
let second = "66666666-7777-8888-9999-000000000000:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
defer { try? FalKeyStore.delete(service: service) }

check(!FalKeyStore.hasKey(service: service), "nothing stored yet")
check(FalKeyStore.read(.silent, service: service) == .missing, "a missing key reads as missing")
do {
    try FalKeyStore.save("Key \(first)\n", service: service)   // 粘进来带前缀和换行
} catch {
    check(false, "saving failed: \(error)")
}
check(FalKeyStore.hasKey(service: service), "the key is there after saving")
check(FalKeyStore.read(.silent, service: service) == .key(first), "the key reads back (tidied), silently")
do { try FalKeyStore.save(second, service: service) } catch { check(false, "replacing failed: \(error)") }
check(FalKeyStore.read(.silent, service: service) == .key(second), "a second save replaces the key")
check(FalKeyStore.read(.interactive, service: service) == .key(second), "the interactive read gives the same key")
do { try FalKeyStore.delete(service: service) } catch { check(false, "deleting failed: \(error)") }
check(!FalKeyStore.hasKey(service: service), "the key is gone after deleting")
check(FalKeyStore.read(.silent, service: service) == .missing, "and reads as missing")
do { try FalKeyStore.delete(service: service) } catch { check(false, "deleting nothing is not an error: \(error)") }
do { try FalKeyStore.save("nope", service: service); check(false, "a bad key must be refused") } catch {}
check(!FalKeyStore.hasKey(service: service), "a refused key stores nothing")

if failures > 0 {
    print("✗ \(failures) of \(checks) keychain checks failed.")
    exit(1)
}
print("All \(checks) fal keychain checks passed.")
