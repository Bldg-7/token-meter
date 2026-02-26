require "fileutils"
require "xcodeproj"

APP_NAME = "TokenMeter"
PROJECT_PATH = "#{APP_NAME}.xcodeproj"

FileUtils.rm_rf(PROJECT_PATH)

project = Xcodeproj::Project.new(PROJECT_PATH)
project.root_object.attributes["LastUpgradeCheck"] = "1700"

main_group = project.main_group

app_sources_group = main_group.new_group(APP_NAME)
widget_sources_group = main_group.new_group("#{APP_NAME}Widget")
unit_tests_group = main_group.new_group("#{APP_NAME}Tests")
ui_tests_group = main_group.new_group("#{APP_NAME}UITests")

app_target = project.new_target(:application, APP_NAME, :osx, "13.0")
widget_target = project.new_target(:app_extension, "#{APP_NAME}WidgetExtension", :osx, "13.0")
unit_tests_target = project.new_target(:unit_test_bundle, "#{APP_NAME}Tests", :osx, "13.0")
ui_tests_target = project.new_target(:ui_test_bundle, "#{APP_NAME}UITests", :osx, "13.0")

app_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.tokenmeter.app"
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
  config.build_settings["SWIFT_VERSION"] = "6.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["CODE_SIGNING_ALLOWED"] = "YES"
  config.build_settings["INFOPLIST_FILE"] = "#{APP_NAME}/Info.plist"
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "#{APP_NAME}/#{APP_NAME}.entitlements"
end

widget_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.tokenmeter.app.widget"
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
  config.build_settings["SWIFT_VERSION"] = "6.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["CODE_SIGNING_ALLOWED"] = "YES"
  config.build_settings["INFOPLIST_FILE"] = "#{APP_NAME}Widget/Info.plist"
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "#{APP_NAME}Widget/#{APP_NAME}Widget.entitlements"
  config.build_settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  config.build_settings["SKIP_INSTALL"] = "YES"
end

unit_tests_target.build_configurations.each do |config|
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
  config.build_settings["SWIFT_VERSION"] = "6.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.tokenmeter.app.tests"
  config.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/#{APP_NAME}.app/Contents/MacOS/#{APP_NAME}"
  config.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
end

ui_tests_target.build_configurations.each do |config|
  config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
  config.build_settings["SWIFT_VERSION"] = "6.0"
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.tokenmeter.app.uitests"
end

unit_tests_target.add_dependency(app_target)
ui_tests_target.add_dependency(app_target)
app_target.add_dependency(widget_target)

embed_phase = app_target.new_copy_files_build_phase("Embed App Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
embed_phase.add_file_reference(widget_target.product_reference, true)

def add_sources(project:, target:, group:, glob:)
  Dir.glob(glob).sort.each do |path|
    next if File.directory?(path)
    file_ref = group.new_file(path)
    target.add_file_references([file_ref])
  end
end

def add_resources(target:, group:, glob:)
  Dir.glob(glob).sort.each do |path|
    next if File.directory?(path)
    file_ref = group.new_file(path)
    target.resources_build_phase.add_file_reference(file_ref)
  end
end

def add_specific_sources(target:, group:, paths:)
  paths.each do |path|
    file_ref = group.new_file(path)
    target.add_file_references([file_ref])
  end
end

add_sources(project: project, target: app_target, group: app_sources_group, glob: "#{APP_NAME}/**/*.swift")
add_resources(target: app_target, group: app_sources_group, glob: "#{APP_NAME}/*.lproj/*.strings")
add_sources(project: project, target: widget_target, group: widget_sources_group, glob: "#{APP_NAME}Widget/*.swift")
add_specific_sources(
  target: widget_target,
  group: widget_sources_group,
  paths: [
    "#{APP_NAME}/Widget/WidgetSharedConfig.swift",
    "#{APP_NAME}/Widget/WidgetSnapshotDTO.swift",
    "#{APP_NAME}/Widget/WidgetSnapshotStore.swift"
  ]
)
add_sources(project: project, target: unit_tests_target, group: unit_tests_group, glob: "#{APP_NAME}Tests/*.swift")
add_resources(target: unit_tests_target, group: unit_tests_group, glob: "#{APP_NAME}Tests/Fixtures/*")
add_sources(project: project, target: ui_tests_target, group: ui_tests_group, glob: "#{APP_NAME}UITests/*.swift")

project.save

scheme_dir = File.join(PROJECT_PATH, "xcshareddata", "xcschemes")
FileUtils.mkdir_p(scheme_dir)

scheme_path = File.join(scheme_dir, "#{APP_NAME}.xcscheme")
widget_scheme_path = File.join(scheme_dir, "#{APP_NAME}WidgetExtension.xcscheme")

scheme_xml = <<~XML
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "#{app_target.uuid}"
               BuildableName = "#{APP_NAME}.app"
               BlueprintName = "#{APP_NAME}"
               ReferencedContainer = "container:#{PROJECT_PATH}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
       <Testables>
          <TestableReference
             skipped = "NO">
             <BuildableReference
                BuildableIdentifier = "primary"
                BlueprintIdentifier = "#{unit_tests_target.uuid}"
                BuildableName = "#{APP_NAME}Tests.xctest"
                BlueprintName = "#{APP_NAME}Tests"
                ReferencedContainer = "container:#{PROJECT_PATH}">
             </BuildableReference>
          </TestableReference>
       </Testables>
    </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "#{app_target.uuid}"
            BuildableName = "#{APP_NAME}.app"
            BlueprintName = "#{APP_NAME}"
            ReferencedContainer = "container:#{PROJECT_PATH}">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "#{app_target.uuid}"
            BuildableName = "#{APP_NAME}.app"
            BlueprintName = "#{APP_NAME}"
            ReferencedContainer = "container:#{PROJECT_PATH}">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
XML

File.write(scheme_path, scheme_xml)

widget_scheme_xml = <<~XML
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "#{widget_target.uuid}"
               BuildableName = "#{APP_NAME}WidgetExtension.appex"
               BlueprintName = "#{APP_NAME}WidgetExtension"
               ReferencedContainer = "container:#{PROJECT_PATH}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "#{app_target.uuid}"
            BuildableName = "#{APP_NAME}.app"
            BlueprintName = "#{APP_NAME}"
            ReferencedContainer = "container:#{PROJECT_PATH}">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
XML

File.write(widget_scheme_path, widget_scheme_xml)

puts "Generated #{PROJECT_PATH}"
