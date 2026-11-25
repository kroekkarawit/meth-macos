import Foundation

/// Languages supported by Meth (app and CLI).
public enum CLILanguage: String, CaseIterable, Sendable {
    case en
    case th
    case zhHans = "zh-Hans"

    public init?(code: String) {
        let c = code.lowercased().replacingOccurrences(of: "_", with: "-")
        if c == "en" || c.hasPrefix("en-") { self = .en }
        else if c == "th" || c.hasPrefix("th-") { self = .th }
        else if c == "zh" || c.hasPrefix("zh-hans") || c == "zh-cn" || c == "zh-sg" || c.hasPrefix("zh-cn") { self = .zhHans }
        else { return nil }
    }

    /// Resolution order: `--lang` → `METH_LANG` → language chosen in Meth.app →
    /// macOS preferred languages → English.
    public static func resolve(explicit: CLILanguage?, environment: [String: String],
                               appLanguages: [String]?, preferred: [String]) -> CLILanguage {
        if let explicit { return explicit }
        if let env = environment["METH_LANG"], let l = CLILanguage(code: env) { return l }
        for code in (appLanguages ?? []) + preferred {
            if let l = CLILanguage(code: code) { return l }
        }
        return .en
    }
}

/// Localized strings for the CLI. The CLI is a bare executable without a resource
/// bundle, so its (small) string table lives in code. JSON output is never localized.
public struct CLIStrings: Sendable {
    public enum Label: Sendable { case mode, status, remaining, active, inactive, indefinite, error, warning, untilQuit }

    public let language: CLILanguage
    public init(_ language: CLILanguage) { self.language = language }

    public func label(_ l: Label) -> String {
        switch (language, l) {
        case (.en, .mode): "Mode"
        case (.en, .status): "Status"
        case (.en, .remaining): "Remaining"
        case (.en, .active): "Active"
        case (.en, .inactive): "Inactive"
        case (.en, .indefinite): "Indefinite"
        case (.en, .error): "Error"
        case (.en, .warning): "Warning"
        case (.en, .untilQuit): "Ends when this quits"
        case (.th, .mode): "โหมด"
        case (.th, .status): "สถานะ"
        case (.th, .remaining): "เวลาที่เหลือ"
        case (.th, .active): "ทำงานอยู่"
        case (.th, .inactive): "ไม่ทำงาน"
        case (.th, .indefinite): "ไม่จำกัดเวลา"
        case (.th, .error): "ข้อผิดพลาด"
        case (.th, .warning): "คำเตือน"
        case (.th, .untilQuit): "จบเมื่อโปรแกรมนี้ปิด"
        case (.zhHans, .mode): "模式"
        case (.zhHans, .status): "状态"
        case (.zhHans, .remaining): "剩余时间"
        case (.zhHans, .active): "运行中"
        case (.zhHans, .inactive): "未运行"
        case (.zhHans, .indefinite): "无限期"
        case (.zhHans, .error): "错误"
        case (.zhHans, .warning): "警告"
        case (.zhHans, .untilQuit): "此程序退出时结束"
        }
    }

    /// Localized explanation for an error code. Falls back to the English diagnostic.
    public func message(for error: MethError) -> String {
        switch language {
        case .en:
            return error.message
        case .th:
            switch error.code {
            case .usage: return "การใช้งานไม่ถูกต้อง: \(error.message)"
            case .unknownCommand: return "ไม่รู้จักคำสั่งนี้ ลองพิมพ์ `meth help`"
            case .invalidDuration: return "ระยะเวลาไม่ถูกต้อง ใช้รูปแบบเช่น 30m, 2h, 1h30m, 45s หรือ inf (\(error.message))"
            case .durationRequired: return "โหมด Overdose ต้องระบุระยะเวลา (ไม่เกิน 24h) เช่น `meth overdose --for 1h`"
            case .agentUnavailable: return "ติดต่อ Meth ไม่ได้ กรุณาเปิด Meth.app หนึ่งครั้ง แล้วลองใหม่"
            case .helperUnavailable: return "ไม่พบตัวช่วยสิทธิ์ผู้ดูแลระบบของ Overdose เปิด Meth.app แล้วเปิดใช้ Overdose จากเมนูก่อน"
            case .helperRequiresApproval: return "ต้องอนุญาต Meth ใน การตั้งค่าระบบ › ทั่วไป › รายการล็อกอิน ก่อนใช้ Overdose"
            case .overdoseNotAllowed: return "ปิดการใช้ Overdose จากบรรทัดคำสั่งอยู่ เปิดได้ที่เมนูของ Meth › “อนุญาต Overdose จากบรรทัดคำสั่ง”"
            case .overdoseUnsupported: return "Mac เครื่องนี้ไม่รองรับ Overdose (disablesleep)"
            case .indefiniteOverdoseRequiresConfirmation: return "Overdose แบบไม่จำกัดเวลาต้องยืนยันใน Meth.app"
            case .assertionFailed: return "สร้าง power assertion ไม่สำเร็จ (\(error.message))"
            case .privilegedOperationFailed: return "การตั้งค่าพลังงานของระบบล้มเหลว (\(error.message))"
            case .restoreConflict: return "มีการเปลี่ยนการตั้งค่าพลังงานจากที่อื่น Meth จึงไม่เขียนทับ (\(error.message))"
            case .unauthorizedClient: return "ไม่ได้รับอนุญาต"
            case .processNotFound: return "ไม่พบโปรเซสนี้ที่กำลังทำงาน (\(error.message))"
            case .notExtendable: return "ต่อเวลาไม่ได้: ต้องมี session แบบจับเวลากำลังทำงานอยู่"
            case .batteryLow: return "แบตเตอรี่ต่ำกว่าขีดจำกัดที่ตั้งไว้ใน Meth เสียบสายชาร์จหรือเปลี่ยนขีดจำกัดก่อน (\(error.message))"
            case .internal: return "ข้อผิดพลาดภายใน (\(error.message))"
            }
        case .zhHans:
            switch error.code {
            case .usage: return "用法错误：\(error.message)"
            case .unknownCommand: return "未知命令。请运行 `meth help`。"
            case .invalidDuration: return "时长无效。请使用 30m、2h、1h30m、45s 或 inf 等格式。（\(error.message)）"
            case .durationRequired: return "Overdose 必须指定时长（不超过 24h），例如 `meth overdose --for 1h`。"
            case .agentUnavailable: return "无法连接 Meth。请先打开一次 Meth.app，然后重试。"
            case .helperUnavailable: return "未找到 Overdose 所需的特权助手。请打开 Meth.app 并从菜单启用 Overdose。"
            case .helperRequiresApproval: return "请先在“系统设置 › 通用 › 登录项”中允许 Meth，然后再使用 Overdose。"
            case .overdoseNotAllowed: return "已禁止从命令行启用 Overdose。可在 Meth 菜单中开启“允许从命令行使用 Overdose”。"
            case .overdoseUnsupported: return "此 Mac 不支持 Overdose（disablesleep）。"
            case .indefiniteOverdoseRequiresConfirmation: return "无限期 Overdose 需要在 Meth.app 中确认。"
            case .assertionFailed: return "创建电源断言失败。（\(error.message)）"
            case .privilegedOperationFailed: return "修改系统电源设置失败。（\(error.message)）"
            case .restoreConflict: return "电源设置已被其他程序更改，Meth 不会覆盖。（\(error.message)）"
            case .unauthorizedClient: return "未经授权。"
            case .processNotFound: return "找不到正在运行的该进程。（\(error.message)）"
            case .notExtendable: return "无法延长：需要有正在计时的会话。"
            case .batteryLow: return "电池电量低于 Meth 中设置的下限。请接通电源或更改下限。（\(error.message)）"
            case .internal: return "内部错误。（\(error.message)）"
            }
        }
    }

    public var help: String {
        switch language {
        case .en: return """
            Meth — Keep your Mac high. Never asleep.

            USAGE
              meth <command> [--for <duration> | --until HH:MM] [--while-pid <pid>] [--json] [--lang en|th|zh]

            COMMANDS
              bump      Keep the Mac awake; the display may sleep   (caffeinate -i)
              high      Keep the Mac and the display awake          (caffeinate -di)
              overdose  Also disable system sleep (admin helper, --for required, ≤ 24h)
              sober     Restore normal sleep (alias: stop)
              extend D  Add time to the running session, e.g. meth extend 30m
              status    Show the current mode and remaining time
              version   Print the version
              help      Show this help

            DURATIONS
              15m  90m  2h  1h30m  45s  1d  inf     (bump/high without --for run until `meth sober`)

            OPTIONS
              --for D           Stop after a duration
              --until HH:MM     Stop at a time of day (24-hour, local time)
              --while-pid PID   Also stop when that process exits (e.g. --while-pid $$)

            EXAMPLES
              meth high --for 2h
              meth high --until 18:00
              meth bump --while-pid $$        # until this shell exits
              meth status --json
              meth sober

            EXIT CODES
              0 ok · 1 internal · 2 usage · 3 Meth not reachable · 4 Overdose unavailable/not allowed
              5 power operation failed · 6 unauthorized

            Parody notice: the names are a joke about macOS power management. Nothing else.
            """
        case .th: return """
            Meth — ให้ Mac ของคุณไม่หลับ

            การใช้งาน
              meth <คำสั่ง> [--for <ระยะเวลา> | --until HH:MM] [--while-pid <pid>] [--json] [--lang en|th|zh]

            คำสั่ง
              bump      ไม่ให้ Mac หลับ แต่จอดับได้ตามปกติ           (caffeinate -i)
              high      ไม่ให้ทั้ง Mac และจอหลับ                     (caffeinate -di)
              overdose  ปิดการหลับของระบบด้วย (ต้องมีตัวช่วยผู้ดูแลระบบ ต้องใส่ --for ไม่เกิน 24h)
              sober     กลับสู่การหลับปกติ (ใช้ stop ได้)
              extend D  ต่อเวลา session ที่ทำงานอยู่ เช่น meth extend 30m
              status    แสดงโหมดปัจจุบันและเวลาที่เหลือ
              version   แสดงเวอร์ชัน
              help      แสดงวิธีใช้นี้

            ระยะเวลา
              15m  90m  2h  1h30m  45s  1d  inf     (bump/high ที่ไม่ใส่ --for จะทำงานจนกว่าจะสั่ง `meth sober`)

            ตัวเลือก
              --for D           หยุดเมื่อครบระยะเวลา
              --until HH:MM     หยุดเมื่อถึงเวลา (แบบ 24 ชั่วโมง เวลาท้องถิ่น)
              --while-pid PID   หยุดด้วยเมื่อโปรเซสนั้นปิด (เช่น --while-pid $$)

            ตัวอย่าง
              meth high --for 2h
              meth high --until 18:00
              meth bump --while-pid $$        # จนกว่า shell นี้จะปิด
              meth status --json
              meth sober

            รหัสการออก
              0 สำเร็จ · 1 ภายใน · 2 การใช้งาน · 3 ติดต่อ Meth ไม่ได้ · 4 ใช้ Overdose ไม่ได้/ไม่อนุญาต
              5 การจัดการพลังงานล้มเหลว · 6 ไม่ได้รับอนุญาต

            หมายเหตุ: ชื่อทั้งหมดเป็นการล้อเลียน หมายถึงการจัดการพลังงานของ macOS เท่านั้น
            """
        case .zhHans: return """
            Meth — 让你的 Mac 保持清醒，永不睡眠。

            用法
              meth <命令> [--for <时长> | --until HH:MM] [--while-pid <pid>] [--json] [--lang en|th|zh]

            命令
              bump      阻止 Mac 睡眠，显示器可正常关闭           (caffeinate -i)
              high      阻止 Mac 和显示器睡眠                    (caffeinate -di)
              overdose  同时禁用系统睡眠（需要特权助手，必须指定 --for，不超过 24h）
              sober     恢复正常睡眠（别名：stop）
              extend D  延长当前会话，例如 meth extend 30m
              status    显示当前模式和剩余时间
              version   显示版本
              help      显示此帮助

            时长
              15m  90m  2h  1h30m  45s  1d  inf     （bump/high 不带 --for 时将持续到 `meth sober`）

            选项
              --for D           在指定时长后停止
              --until HH:MM     在指定时刻停止（24 小时制，本地时间）
              --while-pid PID   该进程退出时也停止（例如 --while-pid $$）

            示例
              meth high --for 2h
              meth high --until 18:00
              meth bump --while-pid $$        # 直到此 shell 退出
              meth status --json
              meth sober

            退出码
              0 成功 · 1 内部错误 · 2 用法错误 · 3 无法连接 Meth · 4 Overdose 不可用/未允许
              5 电源操作失败 · 6 未授权

            戏仿声明：这些名称只是对 macOS 电源管理的玩笑，别无他意。
            """
        }
    }
}
