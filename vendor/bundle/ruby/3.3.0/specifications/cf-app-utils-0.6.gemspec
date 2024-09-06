# -*- encoding: utf-8 -*-
# stub: cf-app-utils 0.6 ruby lib

Gem::Specification.new do |s|
  s.name = "cf-app-utils".freeze
  s.version = "0.6".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Cloud Foundry".freeze]
  s.date = "2015-08-14"
  s.description = "Helper methods for apps running on Cloud Foundry".freeze
  s.email = ["vcap-dev@cloudfoundry.org".freeze]
  s.homepage = "".freeze
  s.licenses = ["MIT".freeze]
  s.rubygems_version = "3.5.9".freeze
  s.summary = "Helper methods for apps running on Cloud Foundry".freeze

  s.installed_by_version = "3.5.9".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_development_dependency(%q<bundler>.freeze, ["~> 1.3".freeze])
  s.add_development_dependency(%q<rake>.freeze, [">= 0".freeze])
  s.add_development_dependency(%q<rspec>.freeze, [">= 0".freeze])
end
