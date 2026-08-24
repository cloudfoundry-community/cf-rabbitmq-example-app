# The root path is a selector, not an alias for AMQP. A real Blacksmith
# RabbitMQ binding advertises only amqp/amqps/management/management_tls;
# everything else here is derived, or simply unreachable. This page
# reports which is which and lets the viewer remap the bare routes
# (/ping, /queues, /queue/:name) to the protocol of their choice.
#
# Reachable even when nothing is bound (see UNBOUND_ALLOWED in
# lib/app.rb) - that is exactly when an operator needs the binding
# instructions this page also shows.

helpers do
  # credentials.protocols is operator-controlled, not attacker-controlled,
  # but a hostname with a stray "<" would still break the markup - escape
  # every value the view interpolates rather than relying on that.
  def h(value)
    Rack::Utils.escape_html(value.to_s)
  end
end

get '/' do
  if service_binding.bound?
    @bind_instructions = nil
    @protocols = protocol_report
    @selected = selected_protocol
    @mqtt_strategy = selected_mqtt_strategy
  else
    @bind_instructions = BIND_INSTRUCTIONS
    @protocols = []
    @selected = nil
    @mqtt_strategy = nil
  end

  erb :index
end

post '/select' do
  candidate = params['protocol']
  halt 400, 'UNKNOWN-PROTOCOL' unless RabbitMQ::Resolver::PROTOCOLS.include?(candidate)

  # Selection is a protocol name, not a credential - an unsigned cookie is
  # sufficient and keeps the app correct above instances: 1. `secure`
  # follows request.secure?, which Rack derives from X-Forwarded-Proto,
  # so it is set correctly behind the CF router's TLS termination without
  # an environment flag.
  response.set_cookie(
    SELECTION_COOKIE,
    value: candidate,
    path: '/',
    httponly: true,
    same_site: :lax,
    secure: request.secure?
  )
  redirect '/'
end

post '/select-mqtt' do
  candidate = params['mqtt']
  halt 400, 'UNKNOWN-STRATEGY' unless MQTT_STRATEGIES.include?(candidate)

  response.set_cookie(
    MQTT_COOKIE,
    value: candidate,
    path: '/',
    httponly: true,
    same_site: :lax,
    secure: request.secure?
  )
  redirect '/'
end
