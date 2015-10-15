require 'rack/test'
RSpec.configure do |config|
  config.include Rack::Test::Methods
end

if ENV.has_key?('VCAP_SERVICES')
  puts "Not starting local rabbitmq, using the one defined in VCAP_SERVICES"
else
  require 'support/rabbitmq_server'
  RABBITMQ = RabbitMQServer.new(
    host: "localhost",
    port: 5673
  )

  RSpec.configure do |config|
    config.before(:suite) do
      RABBITMQ.start
    end

    config.after(:suite) do
      RABBITMQ.stop
    end
  end
end
