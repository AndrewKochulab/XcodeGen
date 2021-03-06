import Spectre
import XcodeGenKit
import xcodeproj
import PathKit
import ProjectSpec

func projectGeneratorTests() {

    func getProject(_ spec: ProjectSpec) throws -> XcodeProj {
        let generator = ProjectGenerator(spec: spec, path: Path(""))
        return try generator.generateProject()
    }

    func getPbxProj(_ spec: ProjectSpec) throws -> PBXProj {
        return try getProject(spec).pbxproj
    }

    describe("Project Generator") {

        let application = Target(name: "MyApp", type: .application, platform: .iOS,
                                 settings: Settings(buildSettings: BuildSettings(dictionary: ["SETTING_1": "VALUE"])),
                                 dependencies: [.target("MyFramework")])

        let framework = Target(name: "MyFramework", type: .framework, platform: .iOS,
                               settings: Settings(buildSettings: BuildSettings(dictionary: ["SETTING_2": "VALUE"])))

        let targets = [application, framework]

        $0.describe("Config") {

            $0.it("generates config defaults") {
                let spec = ProjectSpec(name: "test")
                let project = try getProject(spec)
                let configs = project.pbxproj.objects.buildConfigurations
                try expect(configs.count) == 2
                try expect(configs).contains(name: "Debug")
                try expect(configs).contains(name: "Release")
            }

            $0.it("generates configs") {
                let spec = ProjectSpec(name: "test", configs: [Config(name: "config1"), Config(name: "config2")])
                let project = try getProject(spec)
                let configs = project.pbxproj.objects.buildConfigurations
                try expect(configs.count) == 2
                try expect(configs).contains(name: "config1")
                try expect(configs).contains(name: "config2")
            }

            $0.it("merges settings") {
                let spec = try ProjectSpec(path: fixturePath + "settings_test.yml")
                guard let config = spec.getConfig("config1") else { throw failure("Couldn't find config1") }
                let debugProjectSettings = spec.getProjectBuildSettings(config: config)

                guard let target = spec.getTarget("Target") else { throw failure("Couldn't find Target") }
                let targetDebugSettings = spec.getTargetBuildSettings(target: target, config: config)

                var buildSettings = BuildSettings()
                buildSettings += SettingsPresetFile.base.getBuildSettings()
                buildSettings += SettingsPresetFile.config(.debug).getBuildSettings()

                buildSettings += [
                    "SETTING": "value",
                    "SETTING 5": "value 5",
                    "SETTING 6": "value 6",
                ]
                try expect(debugProjectSettings) == buildSettings

                var expectedTargetDebugSettings = BuildSettings()
                expectedTargetDebugSettings += SettingsPresetFile.product(.application).getBuildSettings()
                expectedTargetDebugSettings += SettingsPresetFile.platform(.iOS).getBuildSettings()
                expectedTargetDebugSettings += ["SETTING 2": "value 2", "SETTING 3": "value 3", "SETTING": "value"]

                try expect(targetDebugSettings) == expectedTargetDebugSettings
            }
        }

        $0.describe("Targets") {

            let spec = ProjectSpec(name: "test", targets: targets)

            $0.it("generates targets") {
                let pbxProject = try getPbxProj(spec)
                let nativeTargets = pbxProject.objects.nativeTargets
                try expect(nativeTargets.count) == 2
                try expect(nativeTargets.contains { $0.name == application.name }).beTrue()
                try expect(nativeTargets.contains { $0.name == framework.name }).beTrue()
            }

            $0.it("generates dependencies") {
                let pbxProject = try getPbxProj(spec)
                let nativeTargets = pbxProject.objects.nativeTargets
                let dependencies = pbxProject.objects.targetDependencies
                try expect(dependencies.count) == 1
                try expect(dependencies.first!.target) == nativeTargets.first { $0.name == framework.name }!.reference
            }

            $0.it("generates dependencies") {
                let pbxProject = try getPbxProj(spec)
                let nativeTargets = pbxProject.objects.nativeTargets
                let dependencies = pbxProject.objects.targetDependencies
                try expect(dependencies.count) == 1
                try expect(dependencies.first!.target) == nativeTargets.first { $0.name == framework.name }!.reference
            }

            $0.it("generates run scripts") {
                var scriptSpec = spec
                scriptSpec.targets[0].prebuildScripts = [RunScript(script: .script("script1"))]
                scriptSpec.targets[0].postbuildScripts = [RunScript(script: .script("script2"))]
                let pbxProject = try getPbxProj(scriptSpec)

                guard let buildPhases = pbxProject.objects.nativeTargets.first?.buildPhases else { throw failure("Build phases not found") }

                let scripts = pbxProject.objects.shellScriptBuildPhases
                let script1 = scripts[0]
                let script2 = scripts[1]
                try expect(scripts.count) == 2
                try expect(buildPhases.first) == script1.reference
                try expect(buildPhases.last) == script2.reference

                try expect(script1.shellScript) == "script1"
                try expect(script2.shellScript) == "script2"
            }
        }

        $0.describe("Schemes") {

            let buildTarget = Scheme.BuildTarget(target: application.name)
            $0.it("generates scheme") {
                let scheme = Scheme(name: "MyScheme", build: Scheme.Build(targets: [buildTarget]))
                let spec = ProjectSpec(name: "test", targets: [application, framework], schemes: [scheme])
                let project = try getProject(spec)
                guard let target = project.pbxproj.objects.nativeTargets.first(where: { $0.name == application.name }) else { throw failure("Target not found") }
                guard let xcscheme = project.sharedData?.schemes.first else { throw failure("Scheme not found") }
                try expect(scheme.name) == "MyScheme"
                guard let buildActionEntry = xcscheme.buildAction?.buildActionEntries.first else { throw failure("Build Action entry not found") }
                try expect(buildActionEntry.buildFor) == XCScheme.BuildAction.Entry.BuildFor.default

                let buildableReferences: [XCScheme.BuildableReference] = [
                    buildActionEntry.buildableReference,
                    xcscheme.launchAction?.buildableProductRunnable.buildableReference,
                    xcscheme.profileAction?.buildableProductRunnable.buildableReference,
                    xcscheme.testAction?.macroExpansion,
                ].flatMap { $0 }

                for buildableReference in buildableReferences {
                    try expect(buildableReference.blueprintIdentifier) == target.reference
                    try expect(buildableReference.blueprintName) == scheme.name
                    try expect(buildableReference.buildableName) == "\(target.name).\(target.productType!.fileExtension!)"
                }

                try expect(xcscheme.launchAction?.buildConfiguration) == "Debug"
                try expect(xcscheme.testAction?.buildConfiguration) == "Debug"
                try expect(xcscheme.profileAction?.buildConfiguration) == "Release"
                try expect(xcscheme.analyzeAction?.buildConfiguration) == "Debug"
                try expect(xcscheme.archiveAction?.buildConfiguration) == "Release"
            }

            $0.it("generates target schemes from config variant") {
                let configVariants = ["Test", "Production"]
                var target = application
                target.generateSchemes = configVariants
                let configs: [Config] = [
                    Config(name: "Test Debug", type: .debug),
                    Config(name: "Production Debug", type: .debug),
                    Config(name: "Test Release", type: .release),
                    Config(name: "Production Release", type: .release),
                ]

                let spec = ProjectSpec(name: "test", configs: configs, targets: [target, framework])
                let project = try getProject(spec)

                try expect(project.sharedData?.schemes.count) == 2

                guard let nativeTarget = project.pbxproj.objects.nativeTargets.first(where: { $0.name == application.name }) else { throw failure("Target not found") }
                guard let xcscheme = project.sharedData?.schemes.first(where: { $0.name == "\(target.name) Test" }) else { throw failure("Scheme not found") }
                guard let buildActionEntry = xcscheme.buildAction?.buildActionEntries.first else { throw failure("Build Action entry not found") }
                try expect(buildActionEntry.buildableReference.blueprintIdentifier) == nativeTarget.reference

                try expect(xcscheme.launchAction?.buildConfiguration) == "Test Debug"
                try expect(xcscheme.testAction?.buildConfiguration) == "Test Debug"
                try expect(xcscheme.profileAction?.buildConfiguration) == "Test Release"
                try expect(xcscheme.analyzeAction?.buildConfiguration) == "Test Debug"
                try expect(xcscheme.archiveAction?.buildConfiguration) == "Test Release"
            }
        }
    }
}
