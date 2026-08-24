# Sinatra falls back to :development when neither is set, which turns on
# show_exceptions and this app's request logging - the former would mask
# the app's own error handling under test. Set before 'sinatra' loads.
ENV['RACK_ENV'] ||= 'test'

require 'rack/test'
require 'json'
require 'webmock/rspec'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

FIXTURE_DIR = File.expand_path('fixtures', __dir__)

def vcap_fixture(name)
  File.read(File.join(FIXTURE_DIR, 'vcap', "#{name}.json"))
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.disable_monkey_patching!
  config.around(:each) do |example|
    original = ENV['VCAP_SERVICES']
    example.run
    original.nil? ? ENV.delete('VCAP_SERVICES') : ENV.store('VCAP_SERVICES', original)
  end
end
