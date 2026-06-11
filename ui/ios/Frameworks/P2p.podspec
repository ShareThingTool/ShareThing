Pod::Spec.new do |s|
  s.name         = 'P2p'
  s.version      = '1.0.0'
  s.summary      = 'ShareThing Go libp2p engine (gomobile xcframework)'
  s.homepage     = 'https://github.com/your-repo/sharething'
  s.license      = { :type => 'MIT' }
  s.author       = 'ShareThing'
  s.platform     = :ios, '14.0'
  s.source       = { :path => '.' }
  s.vendored_frameworks = 'P2p.xcframework'
  s.libraries = 'resolv.9'
end
