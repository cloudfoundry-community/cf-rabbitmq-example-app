require 'sinatra'
require 'json'

# Custom error blocks below only run when Sinatra is not showing (or
# re-raising) exceptions itself. Left at their defaults, :test env sets
# raise_errors true and a bare "development" default (no RACK_ENV/APP_ENV
# at all - the case for a plain local run) sets show_exceptions true;
# either suppresses every 'error' block below, and show_exceptions hands
# the caller a full source/stack-trace page instead of the documented
# "ERR:..." response - a public information disclosure. Pin both off so
# the contract holds regardless of how the process was started.
set :raise_errors, false
set :show_exceptions, false

$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require 'rabbitmq/binding'
require 'rabbitmq/resolver'
require 'rabbitmq/registry'

BIND_INSTRUCTIONS = <<~TEXT.freeze
  You must bind a RabbitMQ service instance to this application.

  You can run the following commands to create an instance and bind to it:

    $ cf create-service rabbitmq standalone rabbitmq-instance
    $ cf bind-service <app-name> rabbitmq-instance
TEXT

helpers do
  SELECTION_COOKIE = 'rmq_protocol'
  MQTT_COOKIE = 'rmq_mqtt'
  MQTT_STRATEGIES = %w[serialized per-queue per-request].freeze

  # Sinatra::Base#call dups self before delegating to an instance's #call!,
  # so each request gets its own instance - memoizing on an instance
  # variable here is memoizing per-request, not across requests. Without
  # it, service_binding and resolver each re-parse VCAP_SERVICES on every
  # call, and a single request can call them several times.
  def service_binding
    @service_binding ||= RabbitMQ::Binding.from_env
  end

  def resolver
    @resolver ||= RabbitMQ::Resolver.new(service_binding)
  end

  def endpoint_for(protocol)
    resolver.resolve(protocol) ||
      halt(503, "UNAVAILABLE: #{resolver.unavailable_reason(protocol)}")
  end

  def adapter(protocol)
    klass = RabbitMQ::Registry.adapter_for(protocol) ||
            halt(501, "NOT-SUPPORTED: #{protocol}")
    klass.new(endpoint_for(protocol))
  end

  def management
    RabbitMQ::Adapters::Management.new(endpoint_for(management_protocol))
  end

  def management_protocol
    resolver.resolve('management') ? 'management' : 'management_tls'
  end

  # Adapters return [status, body]; routes just relay it.
  def relay(result)
    code, body_text = result
    status code
    body body_text
  end

  # Bare routes default to AMQP but are remappable by explicit selection:
  # a one-request query param, else the cookie the index page sets, else
  # amqp. Anything unrecognised or unresolvable falls back rather than
  # erroring - the selector is a convenience, not a gate.
  def selected_protocol
    candidate = params['protocol'] || request.cookies[SELECTION_COOKIE]
    return fallback_protocol unless candidate
    return fallback_protocol unless RabbitMQ::Resolver::PROTOCOLS.include?(candidate)
    return fallback_protocol unless resolver.resolve(candidate)

    candidate
  end

  def fallback_protocol
    resolver.resolve('amqp') ? 'amqp' : 'amqps'
  end

  # Same resolution order as the protocol selection, with an env default so
  # an operator can set the deployment-wide behaviour without a cookie.
  def selected_mqtt_strategy
    candidate = params['mqtt'] || request.cookies[MQTT_COOKIE] || ENV['MQTT_CONCURRENCY']
    MQTT_STRATEGIES.include?(candidate) ? candidate : 'serialized'
  end
end

before do
  halt 500, BIND_INSTRUCTIONS unless service_binding.bound?
end

require 'routes/legacy'

error RabbitMQ::Adapters::QueueNotFound do
  halt 404, 'NO-SUCH-QUEUE'
end

error RabbitMQ::Adapters::ManagementError do
  err = env['sinatra.error']
  halt 502, "ERR:management API returned #{err.status}: #{err.detail}"
end

error do
  halt 500, "ERR:#{env['sinatra.error'].message}"
end
