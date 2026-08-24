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
set :views, File.expand_path('../views', __dir__)

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

# The index explains what the binding does and does not support, so it
# has to be reachable (and the select routes it posts to) even when
# nothing is bound - that is precisely when an operator needs it most.
# Every other route keeps the unbound 500.
UNBOUND_ALLOWED = ['/', '/select', '/select-mqtt'].freeze

before do
  next if UNBOUND_ALLOWED.include?(request.path_info)

  halt 500, BIND_INSTRUCTIONS unless service_binding.bound?
end

# Shared by lib/routes/legacy.rb (bare routes, whose protocol is chosen
# per request via selected_protocol) and lib/routes/protocol.rb (protocol
# fixed by the URL prefix). This is a plain top-level method, not a
# Sinatra helper: it calls the route DSL (get/post/put) itself, and that
# DSL only resolves from top-level scope, not from inside a helpers block.
#
# protocol_for is a block, not a value, and is run per request with
# instance_exec instead of being called once here. Calling it eagerly
# and interpolating the result would freeze whichever protocol was
# selected on the very first request into every route body forever -
# selected_protocol has to be re-evaluated on every call.
def define_protocol_routes(prefix, &protocol_for)
  get "#{prefix}/ping" do
    relay(adapter(instance_exec(&protocol_for)).ping)
  end

  get "#{prefix}/queues" do
    status 200
    body management.queue_names.map { |q| "#{q}\n" }.join
  end

  post "#{prefix}/queues" do
    halt 400, 'NO-NAME' unless params[:name]
    halt 304, 'EXISTS' if management.queue_exists?(params[:name])

    relay(adapter(instance_exec(&protocol_for)).declare(params[:name]))
  end

  put "#{prefix}/queue/:name" do
    halt 400, 'NO-DATA' unless params[:data]

    relay(adapter(instance_exec(&protocol_for)).publish(params[:name], params[:data]))
  end

  get "#{prefix}/queue/:name" do
    relay(adapter(instance_exec(&protocol_for)).consume(params[:name]))
  end
end

require 'routes/legacy'
require 'routes/protocol'
require 'routes/management'
require 'routes/diagnostics'
require 'routes/index'

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
