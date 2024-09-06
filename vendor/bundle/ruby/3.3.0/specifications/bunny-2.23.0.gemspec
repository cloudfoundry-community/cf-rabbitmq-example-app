# -*- encoding: utf-8 -*-
# stub: bunny 2.23.0 ruby lib

Gem::Specification.new do |s|
  s.name = "bunny".freeze
  s.version = "2.23.0".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "changelog_uri" => "https://github.com/ruby-amqp/bunny/blob/main/ChangeLog.md" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Chris Duncan".freeze, "Eric Lindvall".freeze, "Jakub Stastny aka botanicus".freeze, "Michael S. Klishin".freeze, "Stefan Kaes".freeze]
  s.date = "2024-07-01"
  s.description = "Easy to use, feature complete Ruby client for RabbitMQ 3.9 and later versions.".freeze
  s.email = ["michael.s.klishin@gmail.com".freeze]
  s.extra_rdoc_files = ["README.md".freeze]
  s.files = ["README.md".freeze]
  s.homepage = "http://rubybunny.info".freeze
  s.licenses = ["MIT".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.5".freeze)
  s.rubygems_version = "3.5.9".freeze
  s.summary = "Popular easy to use Ruby client for RabbitMQ".freeze

  s.installed_by_version = "3.5.9".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<amq-protocol>.freeze, ["~> 2.3".freeze, ">= 2.3.1".freeze])
  s.add_runtime_dependency(%q<sorted_set>.freeze, ["~> 1".freeze, ">= 1.0.2".freeze])
end
