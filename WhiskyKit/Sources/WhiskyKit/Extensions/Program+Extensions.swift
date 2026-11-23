//
//  Program+Extensions.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

extension Program {
    public var runtimeSelection: RuntimeTargetSelection { settings.launchTarget ?? .automatic }
    public var runtimeBackend: RuntimeBackendKind? { settings.preferredBackend }

    public func runtimeCoordinator(
        remotePhysicsAvailability: RemotePhysicsAvailability? = nil
    ) -> RuntimeCoordinator {
        let remoteProvider: any RemotePhysicsProvider
        if let configuration = bottle.settings.remotePhysicsConfiguration {
            remoteProvider = ExternalClientRemotePhysicsProvider(configuration: configuration)
        } else {
            remoteProvider = UnconfiguredRemotePhysicsProvider()
        }
        return RuntimeCoordinator(
            remotePhysicsProvider: remoteProvider,
            remotePhysicsAvailability: remotePhysicsAvailability
        )
    }

    public func runtimeRequest(arguments: [String]? = nil,
                               selection: RuntimeTargetSelection? = nil,
                               backend: RuntimeBackendKind? = nil) throws -> RuntimeLaunchRequest {
        RuntimeLaunchRequest(executableURL: url, bottle: bottle,
                             arguments: try arguments ?? RuntimeArguments.parse(settings.arguments),
                             environment: generateEnvironment(), selection: selection ?? runtimeSelection,
                             backend: backend ?? runtimeBackend)
    }

    public func runtimeStoragePreflight(
        selection: RuntimeTargetSelection? = nil, backend: RuntimeBackendKind? = nil,
        targetDirectory: URL? = nil, guestConfiguration: RuntimeGuestConfiguration? = nil
    ) -> RuntimeStoragePreflight {
        runtimeCoordinator().storagePreflight(
            for: url, bottle: bottle, selection: selection ?? runtimeSelection,
            backend: backend ?? runtimeBackend,
            targetDirectory: targetDirectory, guestConfiguration: guestConfiguration
        )
    }

    public func validateRuntimeLaunch(
        selection: RuntimeTargetSelection? = nil,
        backend: RuntimeBackendKind? = nil
    ) throws {
        let request = try runtimeRequest(selection: selection, backend: backend)
        _ = try runtimeCoordinator().validate(request, allowUnverifiedRemotePhysics: true)
    }

    public func launchWithRuntime(
        arguments: [String]? = nil,
        selection: RuntimeTargetSelection? = nil,
        backend: RuntimeBackendKind? = nil
    ) async throws {
        let request = try runtimeRequest(arguments: arguments, selection: selection, backend: backend)
        try await runtimeCoordinator().launch(request)
    }
}
