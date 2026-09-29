require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'Mac Image Converter.xcodeproj')
project = Xcodeproj::Project.new(project_path)
project.build_configurations.each do |config|
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  config.build_settings['SWIFT_VERSION'] = '5.0'
end

app = project.new_target(:application, 'MacImageConverter', :osx, '14.0')
codec = project.new_target(:static_library, 'WebPCodec', :osx, '14.0')
tests = project.new_target(:unit_test_bundle, 'MacImageConverterTests', :osx, '14.0')
app.add_dependency(codec)
app.frameworks_build_phase.add_file_reference(codec.product_reference)
tests.add_dependency(app)

app_group = project.main_group.new_group('MacImageConverter', 'MacImageConverter')
Dir.glob(File.join(root, 'MacImageConverter/**/*.swift')).sort.each do |path|
  relative = path.delete_prefix(File.join(root, 'MacImageConverter/'))
  reference = app_group.new_file(relative)
  app.source_build_phase.add_file_reference(reference)
end
bridge = app_group.new_file('Processing/WebPBridge.h')
scaled = app_group.new_file('Processing/WebPScaled.c')
codec.source_build_phase.add_file_reference(scaled)
assets = app_group.new_file('Assets.xcassets')
app.resources_build_phase.add_file_reference(assets)

vendor_group = project.main_group.new_group('Vendor', 'Vendor')
webp_group = vendor_group.new_group('libwebp', 'libwebp')
%w[dec dsp enc utils].each do |folder|
  group = webp_group.new_group(folder, "src/#{folder}")
  Dir.glob(File.join(root, "Vendor/libwebp/src/#{folder}/*.c")).sort.each do |path|
    reference = group.new_file(File.basename(path))
    codec.source_build_phase.add_file_reference(reference)
  end
end
sharp_group = webp_group.new_group('sharpyuv', 'sharpyuv')
Dir.glob(File.join(root, 'Vendor/libwebp/sharpyuv/*.c')).sort.each do |path|
  reference = sharp_group.new_file(File.basename(path))
  codec.source_build_phase.add_file_reference(reference)
end

test_group = project.main_group.new_group('MacImageConverterTests', 'MacImageConverterTests')
Dir.glob(File.join(root, 'MacImageConverterTests/*.swift')).sort.each do |path|
  reference = test_group.new_file(File.basename(path))
  tests.source_build_phase.add_file_reference(reference)
end

app.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.local.ImageForge',
    'PRODUCT_NAME' => 'MacImageConverter',
    'MARKETING_VERSION' => '1.2.0',
    'CURRENT_PROJECT_VERSION' => '3',
    'SWIFT_OBJC_BRIDGING_HEADER' => 'MacImageConverter/Processing/WebPBridge.h',
    'HEADER_SEARCH_PATHS' => '$(SRCROOT)/Vendor/libwebp $(SRCROOT)/Vendor/libwebp/src',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'Mac Image Converter',
    'INFOPLIST_KEY_CFBundleShortVersionString' => '1.2.0',
    'INFOPLIST_KEY_CFBundleVersion' => '3',
    'INFOPLIST_KEY_NSHighResolutionCapable' => 'YES',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'SWIFT_VERSION' => '5.0',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO'
  })
end
codec.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_NAME' => 'WebPCodec',
    'HEADER_SEARCH_PATHS' => '$(SRCROOT)/Vendor/libwebp $(SRCROOT)/Vendor/libwebp/src',
    'GCC_C_LANGUAGE_STANDARD' => 'gnu11',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'SKIP_INSTALL' => 'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO'
  })
end
tests.build_configurations.each do |config|
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.local.ImageForgeTests',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'SWIFT_VERSION' => '5.0',
    'CODE_SIGNING_ALLOWED' => 'NO',
    'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/MacImageConverter.app/Contents/MacOS/MacImageConverter',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'HEADER_SEARCH_PATHS' => '$(SRCROOT)/Vendor/libwebp $(SRCROOT)/Vendor/libwebp/src',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO'
  })
end

project.save
