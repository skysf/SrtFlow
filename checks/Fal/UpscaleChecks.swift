import CoreGraphics
import Foundation
import SrtFlowMCPKit

// 第七组：视频 upscale 的档位表、目标分辨率、请求体、估价；第八组：FalClient 的上传和账单明细。
// 估价钉的是 2026-10-02 在南极工程上真跑 19 条、从 fal 账单明细抄下来的数（docs/reports/2026-10-02-upscale-smoke-test.md）：
// 估价只许比账单高或相等（宁多勿少），不许低。

private let hd = CGSize(width: 1280, height: 720)
private let odd = CGSize(width: 1344, height: 768)
private let fhd = CGSize(width: 1920, height: 1080)
private let small = CGSize(width: 640, height: 360)
private let out1080 = CGSize(width: 1920, height: 1080)
private let out1890 = CGSize(width: 1890, height: 1080)
private let out1152 = CGSize(width: 2016, height: 1152)

private func tier(_ id: String) -> FalUpscaleTier {
    guard let found = FalUpscaleTiers.tier(id) else {
        check(false, "no tier called \(id)")
        return FalUpscaleTiers.all[0]
    }
    return found
}

private func body(_ id: String, source: CGSize = hd, target: FalUpscaleTarget = .p1080, fps: Double = 24) -> JSONValue {
    let tier = tier(id)
    return tier.body(videoURL: "https://v3b.fal.media/files/b/x/clip01.mp4", plan: tier.plan(source: source, target: target), sourceFrameRate: fps)
}

private func estimate(_ id: String, _ seconds: Double, _ output: CGSize) -> Double {
    tier(id).pricing.estimate(seconds: seconds, outputSize: output)
}

func runUpscaleChecks() {
    // ---- 档位表：用户 2026-10-02 定的六个，四个端点
    let tiers = FalUpscaleTiers.all
    checkEqual(
        tiers.map(\.id), ["topaz-precision", "topaz-generative", "flux-precise", "flux-creative", "bytedance-standard", "bytedance-pro"],
        "the six tiers the user chose, in display order"
    )
    checkEqual(FalUpscaleTiers.endpoints.count, 4, "the six tiers live on four endpoints")
    checkEqual(Set(tiers.map(\.id)).count, tiers.count, "tier ids are unique")
    for tier in tiers {
        check(FalModels.isValidEndpoint(tier.endpoint), "\(tier.id): \(tier.endpoint) is a valid endpoint id")
        check(!tier.title.isEmpty && !tier.detail.isEmpty && !tier.vendor.isEmpty, "\(tier.id) has a title, a detail and a vendor")
        check(FalUpscaleTiers.tier(tier.id) == tier, "tier(\(tier.id)) finds it")
        check(tier.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }, "\(tier.id) is safe inside a file name")
        check(tier.factorRange.lowerBound >= 1 && tier.factorRange.upperBound <= 10, "\(tier.id): the factor range is sane")
        checkEqual(tier.maxSeconds, 1_500, "\(tier.id): a video upscale may take up to 25 minutes")
    }
    check(!tiers.contains { $0.endpoint == "topaz/upscale/video/creative" }, "Topaz creative is not offered (5 s took ten minutes)")
    check(!tiers.contains { $0.endpoint.hasPrefix("bria/") }, "Bria is not offered (2x only, little gain)")
    for endpoint in FalUpscaleTiers.endpoints {
        if let schema = FalSchema(endpoint: endpoint) {
            checkEqual(schema.submitPath, "/" + endpoint, "the schema snapshot of \(endpoint) is for that endpoint")
            check(schema.input != nil && schema.output != nil, "the snapshot of \(endpoint) has an input and an output schema")
        } else {
            check(false, "no schema snapshot for \(endpoint) (scripts/fal-models/refresh.sh downloads it)")
        }
    }

    // ---- 目标：按短边
    checkEqual(FalUpscaleTarget.allCases.map(\.label), ["1080p", "1440p", "4K"], "three targets")
    checkEqual(FalUpscaleTarget.allCases.map(\.shortSide), [1080, 1440, 2160], "targets are short sides")
    checkClose(FalUpscaleTarget.p1080.factor(for: hd), 1.5, "720p to 1080p is 1.5x")
    checkClose(FalUpscaleTarget.p1080.factor(for: odd), 1.40625, "1344×768 to 1080 high is 1.40625x")
    checkClose(FalUpscaleTarget.p1080.factor(for: CGSize(width: 720, height: 1280)), 1.5, "portrait counts the short side too")
    check(FalUpscaleTarget.p1080.applies(to: hd) && !FalUpscaleTarget.p1080.applies(to: fhd), "1080p applies to a 720p source, not to a 1080p one")
    check(FalUpscaleTarget.p1440.applies(to: fhd) && FalUpscaleTarget.p2160.applies(to: fhd), "a 1080p source can still go to 1440p or 4K")
    check(!FalUpscaleTarget.p2160.applies(to: CGSize(width: 3840, height: 2160)), "4K has nowhere to go")

    // ---- 计划：倍数按模型夹、输出取偶数
    checkEqual(tier("topaz-precision").plan(source: hd, target: .p1080), FalUpscalePlan(factor: 1.5, outputSize: out1080), "Topaz: 720p → 1920×1080")
    checkEqual(tier("topaz-precision").plan(source: odd, target: .p1080).outputSize, out1890, "Topaz: 1344×768 lands exactly on 1080 high")
    checkEqual(tier("flux-precise").plan(source: odd, target: .p1080), FalUpscalePlan(factor: 1.5, outputSize: out1152), "FLUX cannot go below 1.5x, so 1344×768 becomes 2016×1152")
    checkEqual(tier("flux-creative").plan(source: hd, target: .p2160).factor, 3, "FLUX: 720p to 4K is its maximum 3x")
    checkEqual(tier("topaz-precision").plan(source: small, target: .p2160), FalUpscalePlan(factor: 4, outputSize: CGSize(width: 2560, height: 1440)), "Topaz stops at 4x, so 360p reaches 1440p, not 4K")
    checkEqual(tier("bytedance-standard").plan(source: hd, target: .p2160), FalUpscalePlan(factor: 3, outputSize: CGSize(width: 3840, height: 2160)), "ByteDance: 720p → 4K")
    checkClose(tier("bytedance-standard").plan(source: CGSize(width: 1900, height: 1070), target: .p1080).factor, 1.1, "ByteDance's smallest ratio is 1.1")
    let uneven = tier("topaz-precision").plan(source: CGSize(width: 1281, height: 721), target: .p1080).outputSize
    check(Int(uneven.width) % 2 == 0 && Int(uneven.height) % 2 == 0, "output sizes are even")
    checkEqual(tier("topaz-precision").plan(source: out1080, target: .p1080).factor, 1, "a source already at the target is 1x")

    // ---- 请求体：每个档位 × 每档目标 × 几种源，逐条对着接口定义快照验
    for tier in tiers {
        for target in FalUpscaleTarget.allCases {
            for source in [hd, odd, fhd, small] where target.applies(to: source) {
                let request = body(tier.id, source: source, target: target)
                checkValidInput(tier.endpoint, request, "\(tier.id) to \(target.label) from \(Int(source.width))×\(Int(source.height))")
                checkEqual(request["video_url"], "https://v3b.fal.media/files/b/x/clip01.mp4", "\(tier.id): the uploaded file's address is the video_url")
            }
        }
    }
    // 档位各自的字段
    checkEqual(body("topaz-precision")["model"], "Proteus", "Topaz precision uses Proteus")
    checkEqual(body("topaz-generative")["model"], "Starlight Precise 2.6", "Topaz generative uses Starlight Precise 2.6")
    checkEqual(body("flux-precise")["creativity"], 0, "FLUX precise sends creativity 0 explicitly (fal's default is 1)")
    checkEqual(body("flux-creative")["creativity"], 1, "FLUX creative sends creativity 1")
    checkEqual(body("bytedance-standard")["enhancement_tier"], "standard", "ByteDance standard")
    checkEqual(body("bytedance-pro")["enhancement_tier"], "pro", "ByteDance pro")
    checkEqual(body("bytedance-standard")["enhancement_preset"], "aigc", "ByteDance uses the AI-footage preset")
    checkEqual(body("bytedance-standard")["fidelity"], "high", "ByteDance stays close to the source")
    checkEqual(body("bytedance-standard")["scale_ratio"], 1.5, "ByteDance gets the ratio, not a named resolution")
    checkEqual(body("bytedance-standard", fps: 24)["target_fps"], 24, "the source frame rate is sent so ByteDance does not interpolate to 30")
    checkEqual(body("bytedance-standard", fps: 23.976)["target_fps"], 24, "23.976 fps rounds to 24")
    checkEqual(body("bytedance-standard", fps: 15)["target_fps"], 24, "ByteDance accepts 24 fps at least")
    checkEqual(body("bytedance-standard", fps: 240)["target_fps"], 120, "...and 120 at most")
    checkEqual(body("topaz-precision")["upscale_factor"], 1.5, "Topaz gets the factor")
    checkEqual(body("topaz-precision", source: odd)["upscale_factor"], 1.40625, "a fractional factor is sent as is")
    check(body("topaz-precision")["target_fps"] == nil && body("flux-precise")["target_fps"] == nil, "only ByteDance is told a frame rate")
    check(body("topaz-precision")["H264_output"] == nil, "Topaz keeps its default codec (HEVC); the caller re-wraps the result anyway")

    // ---- 估价：钉在 2026-10-02 的账单上（估 ≥ 实收）
    checkClose(estimate("bytedance-standard", 6.016, out1080), 0.0433152, "ByteDance standard: 6.016 s at 1080p was billed $0.0433", tolerance: 1e-7)
    checkClose(estimate("bytedance-standard", 10.145, out1890), 0.073044, "...10.145 s at 1890×1080 was billed $0.0730", tolerance: 1e-7)
    checkClose(estimate("bytedance-pro", 5.184, out1890), 0.37332, "ByteDance pro: 5.184 s was billed $0.3733 (ten times standard)", tolerance: 1e-3)
    checkClose(estimate("bytedance-standard", 6, CGSize(width: 2560, height: 1440)), 0.0864, "ByteDance 2K is twice the 1080p rate")
    checkClose(estimate("bytedance-standard", 6, CGSize(width: 3840, height: 2160)), 0.1728, "ByteDance 4K is four times")
    checkClose(estimate("flux-precise", 6.042, out1080), 0.896, "FLUX precise: 6.042 s at 1920×1080 was billed $0.896", tolerance: 0.004)
    checkClose(estimate("flux-precise", 6.592, out1152), 1.095, "FLUX precise: 6.592 s at 2016×1152 was billed $1.095 (the price follows the output area)", tolerance: 0.004)
    checkClose(estimate("flux-creative", 6.042, out1080), 1.2545, "FLUX creative: 6.042 s was billed $1.2545", tolerance: 0.004)
    checkClose(estimate("topaz-precision", 9.002, out1080), 0.20, "Topaz precision: 9 s was billed $0.20")
    checkClose(estimate("topaz-precision", 3.008, out1080), 0.10, "Topaz precision: 3 s was billed $0.10, the floor is one $0.10 step")
    checkClose(estimate("topaz-precision", 8.0, out1080), 0.20, "Topaz precision: 8 s was billed $0.10; the estimate rounds the page price up, never down")
    checkClose(estimate("topaz-precision", 10, CGSize(width: 3840, height: 2160)), 0.60, "Topaz precision 4K is $0.60 per 10 s")
    checkClose(estimate("topaz-precision", 10, CGSize(width: 2560, height: 1440)), 0.60, "Topaz has no 2K tier: 1440p is billed as 4K")
    checkClose(estimate("topaz-generative", 5.184, out1890), 0.70, "Topaz generative: 5.18 s was billed $0.60; the estimate rounds up to $0.70")
    checkClose(estimate("topaz-generative", 10, out1080), 1.20, "Topaz generative is $1.20 per 10 s at 1080p")
    checkClose(estimate("topaz-generative", 10, CGSize(width: 3840, height: 2160)), 2.60, "...and $2.60 at 4K")
    checkClose(estimate("topaz-precision", 0, out1080), 0, "nothing costs nothing")
    checkClose(estimate("flux-precise", 0, out1080), 0, "nothing costs nothing (FLUX)")
    let fluxPlan = tier("flux-precise").plan(source: odd, target: .p1080)
    checkClose(tier("flux-precise").estimate(seconds: 6.592, plan: fluxPlan), 1.095, "a plan carries the output size the price depends on", tolerance: 0.004)

    // ---- 账单明细的形状（2026-10-02 真答复的样子）
    let sample = Data("""
    {"billing_events":[
      {"request_id":"01a0faf4-2ff0","endpoint_id":"topaz/upscale/video/precision","timestamp":"2026-10-02T04:52:07.087672000Z","quantity":20,"output_units":20,"unit":"units","unit_price":0.01,"percent_discount":0,"cost_subtotal":0.2,"cost_discount":0,"cost_total":0.2,"cost_estimate_nano_usd":200000000},
      {"request_id":"01a0faf4-6086","endpoint_id":"fal-ai/bytedance-upscaler/upscale/video","timestamp":"2026-10-02T04:53:00Z","output_units":6.016,"unit":"seconds","unit_price":0.0072,"cost_total":0.0433152},
      {"request_id":"broken","endpoint_id":"x/y"}
    ],"next_cursor":null,"has_more":false}
    """.utf8)
    let events = FalBilling.events(from: (try? JSONValue.decode(sample)) ?? .null)
    checkEqual(events.count, 2, "two well-formed events are read, the broken one is skipped")
    checkEqual(events.first, FalBillingEvent(requestID: "01a0faf4-2ff0", endpoint: "topaz/upscale/video/precision", units: 20, unitPrice: 0.01, cost: 0.2), "the Topaz event")
    checkClose(FalBilling.cost(of: "01a0faf4-6086", in: events), 0.0433152, "the cost of one request")
    check(FalBilling.cost(of: "not-yet", in: events) == nil, "a request fal has not billed yet has no cost")
    checkEqual(FalBilling.events(from: .null), [], "no events in nothing")
    let items = FalBilling.query(requestIDs: ["a", "b"], since: Date(timeIntervalSince1970: 1_790_000_000))
    checkEqual(items.filter { $0.name == "request_id" }.map { $0.value ?? "" }, ["a", "b"], "each request id is its own query item")
    checkEqual(items.first { $0.name == "start" }?.value, "2026-09-21T14:13:20Z", "start is ISO 8601 in UTC")
}

func runUpscaleClientChecks() async {
    let client = FalClient(session: FalStub.session, pollInterval: { _ in 0.005 }, key: { "id:secret" })
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fal-upscale-check-\(getpid())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("clip.mp4")
    let payload = Data((0..<3000).map { UInt8($0 % 253) })
    try? payload.write(to: file)

    // ---- 上传：initiate 带 Key、PUT 到存储桶不带 Key、PUT 的体就是文件的字节、回 file_url
    let initiate = "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3"
    let bucket = "https://storage.googleapis.com/fal-cdn/abc?sig=1"
    FalStub.reset { seen in
        switch (seen.method, seen.url) {
        case ("POST", initiate): return .init(200, #"{"upload_url":"\#(bucket)","file_url":"https://v3b.fal.media/files/b/x/clip01.mp4"}"#)
        case ("PUT", bucket): return .init(200, "")
        default: return .init(404, #"{"detail":"unexpected \#(seen.method) \#(seen.url)"}"#)
        }
    }
    do {
        let link = try await client.upload(fileURL: file, contentType: "video/mp4", fileName: "clip01.mp4")
        checkEqual(link.absoluteString, "https://v3b.fal.media/files/b/x/clip01.mp4", "the upload answers with the file's address")
    } catch {
        check(false, "the upload failed: \(error)")
    }
    let log = FalStub.log
    checkEqual(log.map(\.method), ["POST", "PUT"], "initiate, then one PUT")
    checkEqual(log.first?.url, initiate, "initiate asks for fal-cdn-v3 storage (gcs is refused since 2026-10)")
    checkEqual(log.first?.authorization, "Key id:secret", "initiate carries the key")
    check(log.last?.authorization == nil, "the PUT to the storage bucket does not carry the key")
    checkEqual(log.last?.body, payload, "the PUT body is the file's bytes")
    let initiateBody = log.first?.body.flatMap { try? JSONValue.decode($0) }
    checkEqual(initiateBody?["file_name"], "clip01.mp4", "initiate names the file")
    checkEqual(initiateBody?["content_type"], "video/mp4", "initiate names the content type")
    // 没给名字就用文件名
    FalStub.reset { seen in seen.method == "POST" ? .init(200, #"{"upload_url":"\#(bucket)","file_url":"https://v3b.fal.media/f/clip.mp4"}"#) : .init(200, "") }
    _ = try? await client.upload(fileURL: file, contentType: "video/mp4")
    checkEqual(FalStub.log.first?.body.flatMap { try? JSONValue.decode($0) }?["file_name"], "clip.mp4", "without a name the file's own name is used")
    // initiate 被拒
    FalStub.reset { _ in .init(400, #"{"detail":"Invalid storage type"}"#) }
    do {
        _ = try await client.upload(fileURL: file, contentType: "video/mp4")
        check(false, "a refused initiate should throw")
    } catch let error as FalError {
        checkEqual(error, .invalidInput("Invalid storage type"), "a refused initiate is reported with fal's reason")
    } catch {
        check(false, "a refused initiate threw \(error)")
    }
    checkEqual(FalStub.log.count, 1, "nothing is PUT after a refused initiate")
    // initiate 的答复缺地址
    FalStub.reset { _ in .init(200, #"{"ok":true}"#) }
    do {
        _ = try await client.upload(fileURL: file, contentType: "video/mp4")
        check(false, "an initiate answer without addresses should throw")
    } catch let error as FalError {
        checkEqual(error, .badAnswer("no upload_url / file_url"), "an initiate answer without addresses")
    } catch {
        check(false, "an initiate answer without addresses threw \(error)")
    }
    // PUT 失败
    FalStub.reset { seen in seen.method == "POST" ? .init(200, #"{"upload_url":"\#(bucket)","file_url":"https://v3b.fal.media/f/clip.mp4"}"#) : .init(403, #"{"detail":"signature expired"}"#) }
    do {
        _ = try await client.upload(fileURL: file, contentType: "video/mp4")
        check(false, "a failed PUT should throw")
    } catch let error as FalError {
        checkEqual(error, .noBalance("signature expired"), "a failed PUT is reported")
    } catch {
        check(false, "a failed PUT threw \(error)")
    }
    // 文件不存在、没有 Key：一个请求也不发
    FalStub.reset { _ in .init(200, "{}") }
    do {
        _ = try await client.upload(fileURL: folder.appendingPathComponent("missing.mp4"), contentType: "video/mp4")
        check(false, "a missing file should throw")
    } catch let error as FalError {
        if case .network = error { check(true, "a missing file is a network-class error") } else { check(false, "a missing file threw \(error)") }
    } catch {
        check(false, "a missing file threw \(error)")
    }
    let keyless = FalClient(session: FalStub.session, key: { nil })
    do {
        _ = try await keyless.upload(fileURL: file, contentType: "video/mp4")
        check(false, "no key should throw")
    } catch let error as FalError {
        checkEqual(error, .noKey, "no key, no upload")
    } catch {
        check(false, "no key threw \(error)")
    }
    checkEqual(FalStub.log.count, 0, "nothing was sent without a key or without a file")

    // ---- 账单明细：GET api.fal.ai/v1/models/billing-events?start=…&request_id=…，带 Key
    let sample = #"{"billing_events":[{"request_id":"01a0faf4-2ff0","endpoint_id":"topaz/upscale/video/precision","output_units":20,"unit_price":0.01,"cost_total":0.2}],"has_more":false}"#
    FalStub.reset { seen in
        seen.method == "GET" && seen.url.hasPrefix("https://api.fal.ai/v1/models/billing-events?") ? .init(200, sample) : .init(404, "{}")
    }
    do {
        let events = try await client.billingEvents(requestIDs: ["01a0faf4-2ff0", "zzz"], since: Date(timeIntervalSince1970: 1_790_000_000))
        checkEqual(events.map(\.requestID), ["01a0faf4-2ff0"], "the billed request comes back")
        checkClose(FalBilling.cost(of: "01a0faf4-2ff0", in: events), 0.2, "with its cost")
    } catch {
        check(false, "the billing lookup failed: \(error)")
    }
    let billing = FalStub.log.first
    checkEqual(billing?.authorization, "Key id:secret", "the billing lookup carries the key")
    check(billing?.url.contains("request_id=01a0faf4-2ff0") == true && billing?.url.contains("request_id=zzz") == true, "every request id is in the query")
    check(billing?.url.contains("start=2026-09-21T14") == true, "the lookup starts from the given time")
    // 只有 API 权限的 Key：403 → 调用方当作查不到
    FalStub.reset { _ in .init(403, #"{"detail":"Forbidden"}"#) }
    do {
        _ = try await client.billingEvents(requestIDs: ["a"], since: Date())
        check(false, "a forbidden billing lookup should throw")
    } catch let error as FalError {
        checkEqual(error, .noBalance("Forbidden"), "a key without ADMIN scope is reported as refused")
    } catch {
        check(false, "a forbidden billing lookup threw \(error)")
    }
}
