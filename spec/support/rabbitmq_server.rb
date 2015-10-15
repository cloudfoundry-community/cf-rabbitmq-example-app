require "childprocess"
require 'socket'

class RabbitMQServer
  attr_reader :host, :port

  def initialize(options)
    @host = options.fetch(:host)
    @port = options.fetch(:port)

    ENV['RABBITMQ_NODENAME']        = "testing-rabbits"
    ENV['RABBITMQ_NODE_IP_ADDRESS'] = host
    ENV['RABBITMQ_NODE_PORT']       = port.to_s

    @process = ChildProcess.build("rabbitmq-server")
    @process.io.stdout = @process.io.stderr = File.open('rabbitmq.log', 'w+')
  end

  def uri
    "amqp://#{host}:#{port}"
  end

  def start
    process.start
  rescue ChildProcess::Error
    fail "rabbitmq-server could not start. Do you have it installed and on your PATH?"
    exit 1
  end

  def stop
    process.stop if process.alive?
  end

  private

  attr_reader :process
end
