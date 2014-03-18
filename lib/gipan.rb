require 'json'
require 'sinatra'
require 'data_mapper'

module GipAN
  PrettyJsonOptions = {
    indent: '  ',
    space: ' ',
    object_nl: "\n",
    array_nl: "\n",
  }
  UrlRegex = /((([A-Za-z]{3,9}:(?:\/\/)?)(?:[-;:&=\+\$,\w]+@)?[A-Za-z0-9.-]+(:[0-9]+)?|(?:www.|[-;:&=\+\$,\w]+@)[A-Za-z0-9.-]+)((?:\/[\+~%\/.\w-]*)?\??(?:[-\+=&;%@.\w]*)#?(?:[\w]*))?)/
  UrlTemplate = -> url do
    %Q{<a href="#{Rack::Utils.escape_html(url)}">#{Rack::Utils.escape_html(url)}</a>}
  end
  PrettyJsonHtmlTemplate = -> entity do
    <<-END
      <html>
        <head>
          <script src="https://google-code-prettify.googlecode.com/svn/loader/run_prettify.js?lang=json"></script>
        </head>
          <body>
          <pre class="prettyprint">
#{ entity.to_json(PrettyJsonOptions).gsub(UrlRegex, &UrlTemplate) }
          </pre>
        </body>
      </html>
    END
  end
  FormatRegex = /(?:\.(?<format>[^\.\\]+))?/

  module Resource
    def self.included klass
      klass.send :include, DataMapper::Resource
      klass.extend ClassMethods
    end

    def base
      self.class
    end

    def uri root, ext = nil
      "#{base.uri root}/#{id}#{ext && ".#{ext}"}"
    end

    def representation root, ext, embed
      if valid?
        { uri: uri(root, ext) }.tap do |repr|
          properties.select { |property| property.reader_visibility == :public }.each do |property|
            repr[property.name] = property.get(self)
          end
          relationships.select { |relationship| relationship.reader_visibility == :public }.each do |relationship|
            repr[relationship.name] = relationship.get(self) && if embed
              relationship.get(self).representation(root, ext, embed)
            else
              { uri: relationship.get(self).uri(root, ext) }
            end
          end
        end
      else
        { error: true, errors: errors.to_h }
      end
    end

    module ClassMethods
      attr_accessor :api

      def singular_name
        name.split('::').last.gsub(/(?!^)[A-Z]/, '_\0').downcase
      end

      def plural_name
        DataMapper::Inflector.pluralize singular_name
      end

      def belongs_to *args
        super.tap do |relationship|
          define_method :base do
            if relationship.get(self).respond_to? relationship.inverse.name
              relationship.get(self).public_send relationship.inverse.name
            else
              super()
            end
          end
        end
      end

      def has *args
        super.tap do |relationship|
          relationship.instance_variable_set :@api, api
          relationship.define_singleton_method :api do
            @api
          end
          relationship.define_singleton_method :get do |*inner_args|
            super(*inner_args).tap { |items| items.extend CollectionMethods; items.api = api }
          end
        end
      end

      def all *args
        super.tap { |all| all.extend CollectionMethods; all.api = api }
      end

      def base
        respond_to?(:model) ? model : api
      end

      def uri root, ext = nil
        "#{base.uri root}/#{plural_name}#{ext && ".#{ext}"}"
      end

      module CollectionMethods
        attr_accessor :api

        def base
          respond_to?(:source) ? source : api
        end

        def plural_name
          respond_to?(:relationship) ? relationship.name.to_s : super
        end

        def uri root, ext = nil
          "#{base.uri root}/#{plural_name}#{ext && ".#{ext}"}"
        end

        def representation root, ext, embed
          {
            uri: uri(root, ext),
            items: map { |item| item.representation(root, ext, embed) }
          }
        end
      end
    end
  end

  class Api < Sinatra::Application
    def self.create_resource api, resource, root_path, plural_name = resource.plural_name, singular_name = resource.singular_name
      resource.api = self
      collection_uri = "#{root_path}#{plural_name}"
      entity_uri = "#{root_path}#{plural_name}\/(?<#{singular_name}_id>[^\.\\\\]+)"

      api.get(/^#{collection_uri}#{FormatRegex}$/) do
        entities = yield(params)
        render(entities.representation(uri("", format), format, false))
      end

      api.get(/^#{entity_uri}#{FormatRegex}$/) do
        entity = yield(params).get(params["#{singular_name}_id".to_sym])
        if entity
          render(entity.representation(uri("", format), format, false))
        else
          halt 404
        end
      end

      unless resource.respond_to? :abstract? and resource.abstract?
        api.put(/^#{entity_uri}#{FormatRegex}$/) do
          entity = yield(params).get(params["#{singular_name}_id".to_sym])
          if entity
            data = api.parse_post request
            entity.update(Hash[
              resource.properties.select { |property| property.writer_visibility == :public }.map do |property|
                [ property.name, data[property.name.to_s] ]
              end + resource.relationships.map do |relationship|
                if data.key? relationship.name.to_s
                  [ relationship.name, data[relationship.name.to_s] ]
                elsif data.key? "#{relationship.name}_id"
                  [ relationship.name, relationship.target_model.get(data["#{relationship.name}_id"]) ]
                end
              end.compact
            ])
            render(entity.representation(uri, format, false))
          else
            halt 404
          end
        end

        api.delete(/^#{entity_uri}#{FormatRegex}$/) do
          entity = yield(params).get(params["#{singular_name}_id".to_sym])
          if entity
            if entity.destroy
              status 204
            else
              status 409
              # TODO: return messages about why the entity could not be destroyed
            end
          else
            halt 404
          end
        end

        api.post(/^#{collection_uri}#{FormatRegex}$/) do
          data = JSON.parse request.body.read
          entity = yield(params).create(Hash[
            resource.properties.select { |property| property.writer_visibility == :public }.map do |property|
              [ property.name, data[property.name.to_s] ]
            end + resource.relationships.map do |relationship|
              if data.key? relationship.name.to_s
                [ relationship.name, data[relationship.name.to_s] ]
              elsif data.key? "#{relationship.name}_id"
                [ relationship.name, relationship.target_model.get(data["#{relationship.name}_id"]) ]
              end
            end.compact
          ])
          status 201
          headers 'Location' => entity.uri(uri, format)
          render(entity.representation(uri, format, false))
        end
      end

      resource.relationships.reject { |relationship| relationship.child_model == self.class }.each do |relationship|
        if relationship.max > 1
          create_resource api, relationship.child_model, "#{entity_uri}\/", relationship.name do |params|
            entity = yield(params).get(params[:"#{singular_name}_id"])
            if entity
              relationship.get(entity)
            else
              halt 404
            end
          end
        else
          api.get(/#{entity_uri}\/#{Regexp.escape(relationship.name)}#{FormatRegex}/) do
            entity = yield(params).get(params["#{singular_name}_id".to_sym])
            if entity
              render(relationship.get(entity).representation(uri, format, false))
            else
              halt 404
            end
          end
        end
      end
    end

    def self.create_api
      get(/^\/root#{FormatRegex}$/) do
        render(representation(false))
      end

      error do
        render({ error: true, errors: { general: [env['sinatra.error'].message] } })
      end

      not_found do
        render({ error: true, errors: { general: ["resource not found"] } })
      end

      resources.each do |resource|
        create_resource self, resource, "/" do |params|
          resource.all
        end
      end
    end

    def self.finalize
      create_api
      self
    end

    def representation embed
      {
        uri: uri("", format),
        resources: Hash[
          self.class.resources.map { |resource| [ resource.plural_name, resource.uri(uri("", format), format) ] }
        ]
      }
    end

    def calc_port scheme
      return case scheme
      when 'http'; 80
      when 'https'; 443
      end
    end

    def uri root = nil, ext = nil
      root_uri = self.class.uri = to('/').chomp('/')
      "#{root_uri}/root#{ext && ".#{ext}"}"
    end

    def self.uri root = nil
      @uri
    end

    def self.uri= value
      @uri = value
    end

    def self.resource resource
      resources << resource
    end

    def self.resources
      @resources ||= []
    end

    def format
      params[:format] && params[:format].to_sym
    end

    def render entity
      case format
      when nil, :json
        content_type :json
        entity.to_json
      when :'json.html'
        content_type :html
        PrettyJsonHtmlTemplate[entity]
      else
        raise "Unknown render type #{format}"
      end
    end

    def self.parse_post request
      JSON.parse request.body.read
    end
  end
end
