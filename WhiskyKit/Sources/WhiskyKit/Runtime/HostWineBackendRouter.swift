// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Target DirectX API level requested by a Windows title or probe.
public enum HostDirectXAPIRequirement: String, Codable, CaseIterable, Sendable {
    case directX12
    case directX11
    case directX10OrEarlier
    case unknown
}

/// Caller preference when multiple DirectX 11 backends are installed on the host.
public enum HostGraphicsRoutingPreference: String, Codable, CaseIterable, Sendable {
    case performanceFirst
    case compatibilityFallback
}

/// Set of Wine graphics translation backends currently available on this host.
public struct HostAvailableWineBackends: Equatable, Codable, Sendable {
    public let hasD3DMetal: Bool
    public let hasDXMT: Bool
    public let hasDXVK: Bool

    public init(hasD3DMetal: Bool, hasDXMT: Bool, hasDXVK: Bool) {
        self.hasD3DMetal = hasD3DMetal
        self.hasDXMT = hasDXMT
        self.hasDXVK = hasDXVK
    }

    public static let all = HostAvailableWineBackends(hasD3DMetal: true, hasDXMT: true, hasDXVK: true)

    public func contains(_ backend: HostWineGraphicsBackend) -> Bool {
        switch backend {
        case .d3dMetal: return hasD3DMetal
        case .dxmt: return hasDXMT
        case .dxvk: return hasDXVK
        }
    }
}

/// Deterministic three-engine routing decision for Wine DirectX translation.
public struct HostWineBackendRoute: Equatable, Codable, Sendable {
    public let apiRequirement: HostDirectXAPIRequirement
    public let preference: HostGraphicsRoutingPreference
    public let selectedBackend: HostWineGraphicsBackend?
    public let fallbackChain: [HostWineGraphicsBackend]
    public let usedFallback: Bool
    public let reason: String

    public init(
        apiRequirement: HostDirectXAPIRequirement,
        preference: HostGraphicsRoutingPreference,
        selectedBackend: HostWineGraphicsBackend?,
        fallbackChain: [HostWineGraphicsBackend],
        usedFallback: Bool,
        reason: String
    ) {
        self.apiRequirement = apiRequirement
        self.preference = preference
        self.selectedBackend = selectedBackend
        self.fallbackChain = fallbackChain
        self.usedFallback = usedFallback
        self.reason = reason
    }
}

/// Routes DirectX workloads across D3DMetal, DXMT, and DXVK based on API level, preference, and availability.
public enum HostWineBackendRouter {
    public static func route(
        apiRequirement: HostDirectXAPIRequirement,
        preference: HostGraphicsRoutingPreference = .performanceFirst,
        available: HostAvailableWineBackends = .all
    ) -> HostWineBackendRoute {
        let chain: [HostWineGraphicsBackend]
        switch apiRequirement {
        case .directX12:
            // DX12 requires D3DMetal; DXMT and DXVK only cover D3D10/11 (and D3D9 for DXVK).
            chain = [.d3dMetal]
        case .directX11:
            switch preference {
            case .performanceFirst:
                chain = [.dxmt, .d3dMetal, .dxvk]
            case .compatibilityFallback:
                chain = [.dxvk, .dxmt, .d3dMetal]
            }
        case .directX10OrEarlier:
            switch preference {
            case .performanceFirst:
                chain = [.dxmt, .dxvk, .d3dMetal]
            case .compatibilityFallback:
                chain = [.dxvk, .dxmt, .d3dMetal]
            }
        case .unknown:
            switch preference {
            case .performanceFirst:
                chain = [.d3dMetal, .dxmt, .dxvk]
            case .compatibilityFallback:
                chain = [.dxvk, .d3dMetal, .dxmt]
            }
        }

        let selected = chain.first(where: available.contains)
        let primary = chain.first
        let usedFallback = selected != nil && selected != primary
        let reason = routeReason(
            apiRequirement: apiRequirement,
            preference: preference,
            selected: selected,
            primary: primary
        )
        return HostWineBackendRoute(
            apiRequirement: apiRequirement,
            preference: preference,
            selectedBackend: selected,
            fallbackChain: chain,
            usedFallback: usedFallback,
            reason: reason
        )
    }

    private static func routeReason(
        apiRequirement: HostDirectXAPIRequirement,
        preference: HostGraphicsRoutingPreference,
        selected: HostWineGraphicsBackend?,
        primary: HostWineGraphicsBackend?
    ) -> String {
        guard let selected else {
            return "No installed Wine graphics backend satisfies \(apiRequirement.rawValue)."
        }
        if let primary, selected != primary {
            return "Preferred backend \(primary.rawValue) unavailable for \(apiRequirement.rawValue) " +
                "(\(preference.rawValue)); fell back to \(selected.rawValue)."
        }
        switch (apiRequirement, selected) {
        case (.directX12, .d3dMetal):
            return "DX12 routes exclusively to D3DMetal (only supported DX12 backend)."
        case (.directX11, .dxmt):
            return "DX11 performance-first routes to DXMT (direct D3D11-to-Metal translation)."
        case (.directX11, .dxvk):
            return "DX11 compatibility fallback routes to DXVK."
        default:
            return "Selected \(selected.rawValue) for \(apiRequirement.rawValue) (\(preference.rawValue))."
        }
    }
}
