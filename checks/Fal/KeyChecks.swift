import Foundation

// 第六组：粘进来的 Key 怎么整理（纯函数）。
// 真的写钥匙串要一个用户的钥匙串、有的机器上还会弹框，**不在这里跑**：`scripts/check-fal-keychain.sh`（本机手动，不在 check-all 里）。

func runKeyChecks() {
    let secret = "3f2a9c1e-7b1d-4e0a-9d0c-1a2b3c4d5e6f:0123456789abcdef0123456789abcdef"
    checkEqual(FalKeyStore.normalized(secret), secret, "a plain key is kept")
    checkEqual(FalKeyStore.normalized("  \(secret)\n"), secret, "spaces and a newline around it are dropped")
    checkEqual(FalKeyStore.normalized("Key \(secret)"), secret, "a pasted `Key ` prefix is dropped")
    checkEqual(FalKeyStore.normalized("key   \(secret)"), secret, "the prefix in any case, with extra spaces")
    checkEqual(FalKeyStore.normalized("\"\(secret)\""), secret, "quotes around it are dropped")
    checkEqual(FalKeyStore.normalized("`\(secret)`"), secret, "backticks around it are dropped")
    check(FalKeyStore.normalized("") == nil, "an empty key is refused")
    check(FalKeyStore.normalized("   ") == nil, "a blank key is refused")
    check(FalKeyStore.normalized("short") == nil, "a key that is too short is refused")
    check(FalKeyStore.normalized("aaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbb") == nil, "two words are not a key")
    check(FalKeyStore.normalized("aaaaaaaaaa\nbbbbbbbbbbbbbbbb") == nil, "a key with a line break inside is refused")
    check(FalKeyStore.normalized(String(repeating: "k", count: 16)) != nil, "16 characters is enough")
    check(FalKeyStore.defaultService.hasSuffix(".fal"), "the keychain service is per app (bundle id) and ends in .fal")
    checkThrows("saving a key that does not look like one") { try FalKeyStore.save("nope", service: "check.srtflow.never-written") }
}
