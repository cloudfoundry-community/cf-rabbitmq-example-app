# Reports, per protocol, whether the binding advertises it, whether it can
# be derived, and the endpoint (and URL path) that would be used.
# Passwords are never included. This is what makes forge issue #96
# observable from the app instead of a mystery when a mode misbehaves.
get '/protocols' do
  report = RabbitMQ::Resolver::PROTOCOLS.each_with_object({}) do |name, acc|
    path = "/#{name.tr('_', '-')}"
    endpoint = resolver.resolve(name)
    acc[name] =
      if endpoint
        endpoint.to_h.merge(
          'available' => true,
          'adapter' => RabbitMQ::Registry.adapter_for(name) ? 'yes' : 'none',
          'path' => path
        )
      else
        { 'available' => false, 'reason' => resolver.unavailable_reason(name), 'path' => path }
      end
  end

  content_type :json
  status 200
  body JSON.pretty_generate(report)
end
