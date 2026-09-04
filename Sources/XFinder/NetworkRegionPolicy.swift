import Foundation

enum NetworkServicePolicy: String, Sendable {
    case openAI
    case claude
}

enum RegionAvailability: Equatable, Sendable {
    case supported
    case notListed
    case unknown
}

enum NetworkRegionPolicy {
    static let snapshotDate = "2026-09-04"

    // Snapshots of the providers' official API availability lists. The UI links
    // to the live provider pages because those policies can change independently
    // of an XFinder release.
    private static let openAICountryCodes: Set<String> = Set(
        "AF AL DZ AD AO AG AR AM AU AT AZ BS BH BD BB BE BZ BJ BT BO BA BW BR BN BG BF BI CV KH CM CA CF TD CL CO KM CG CD CR CI HR CY CZ DK DJ DM DO EC EG SV GQ ER EE SZ ET FJ FI FR GA GM GE DE GH GR GD GT GN GW GY HT VA HN HU IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MG MW MY MV ML MT MH MR MU MX FM MD MC MN ME MA MZ MM NA NR NP NL NZ NI NE NG MK NO OM PK PW PS PA PG PY PE PH PL PT QA RO RW KN LC VC WS SM ST SA SN RS SC SL SG SK SI SB SO ZA KR SS ES LK SR SE CH SD TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VN YE ZM ZW"
            .split(separator: " ").map(String.init)
    )

    private static let claudeCountryCodes: Set<String> = Set(
        "AL DZ AD AO AG AR AM AU AT AZ BS BH BD BB BE BZ BJ BT BO BA BW BR BN BG BF BI CV KH CM CA TD CL CO KM CG CR CI HR CY CZ DK DJ DM DO EC EG SV GQ EE SZ FJ FI FR GA GM GE DE GH GR GD GT GN GW GY HT VA HN HU IS IN ID IQ IE IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LI LT LU MG MW MY MV MT MH MR MU MX FM MD MC MN ME MA MZ NA NR NP NL NZ NE NG MK NO OM PK PW PS PA PG PY PE PH PL PT QA RO RW KN LC VC WS SM ST SA SN RS SC SL SG SK SI SB ZA KR ES LK SR SE CH TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VN ZM ZW"
            .split(separator: " ").map(String.init)
    )

    static func availability(countryCode: String?, service: NetworkServicePolicy) -> RegionAvailability {
        guard let code = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            code.count == 2
        else { return .unknown }
        let supported = service == .openAI ? openAICountryCodes : claudeCountryCodes
        return supported.contains(code) ? .supported : .notListed
    }
}

enum NetworkAddressLogic {
    static func isProxyFakeIP(_ address: String?) -> Bool {
        guard let address else { return false }
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 198 && (parts[1] == 18 || parts[1] == 19)
    }
}

enum NetworkResponseInterpreter {
    static func verdict(kind: NetworkTargetKind, statusCode: Int, body: Data) -> NetworkResponseVerdict {
        let parsed = parseError(body)
        let searchable = [parsed.type, parsed.code, parsed.message]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let regionRestricted = [
            "unsupported_country", "unsupported country", "unsupported region",
            "not available in your country", "not available in your region",
        ].contains { searchable.contains($0) }

        if regionRestricted {
            return NetworkResponseVerdict(
                status: .regionRestricted,
                summary: "Region restricted",
                errorType: parsed.code ?? parsed.type
            )
        }
        if statusCode >= 500 {
            return NetworkResponseVerdict(
                status: .degraded,
                summary: "HTTP \(statusCode)",
                errorType: parsed.type
            )
        }
        if kind == .openAI || kind == .claude {
            if statusCode == 401 || parsed.type == "authentication_error" {
                return NetworkResponseVerdict(
                    status: .authenticationRequired,
                    summary: "API reached; authentication required",
                    errorType: parsed.type
                )
            }
            if (200..<500).contains(statusCode) {
                return NetworkResponseVerdict(
                    status: .reachable,
                    summary: "API reached (HTTP \(statusCode))",
                    errorType: parsed.type
                )
            }
        }
        if (200..<400).contains(statusCode) {
            return NetworkResponseVerdict(status: .reachable, summary: "HTTP \(statusCode)", errorType: parsed.type)
        }
        if (400..<500).contains(statusCode), kind == .custom {
            return NetworkResponseVerdict(
                status: .reachable,
                summary: "Server reached (HTTP \(statusCode))",
                errorType: parsed.type
            )
        }
        return NetworkResponseVerdict(status: .degraded, summary: "HTTP \(statusCode)", errorType: parsed.type)
    }

    static func parseError(_ data: Data) -> (type: String?, code: String?, message: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil, nil)
        }
        let topType = object["type"] as? String
        guard let error = object["error"] as? [String: Any] else {
            return (topType, object["code"] as? String, object["message"] as? String)
        }
        return (
            error["type"] as? String ?? topType,
            error["code"] as? String,
            error["message"] as? String
        )
    }
}
