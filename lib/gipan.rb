require 'json'
require 'sinatra'
require 'data_mapper'

module GipAN
  module Finders
    DataMapper::Model.append_extensions self

    def self.extended(model)
      model.send :include, InstanceMethods
      model.instance_variable_set(:@finders, {})
      super
    end

    def inherited(model)
      model.instance_variable_set(:@finders, {})

      @finders.each do |repository_name, finders|
        model_finders = model.finders(repository_name)
        finders.each { |finder| model_finders << finder }
      end

      super
    end

    def finders(repository_name = default_repository_name)
      default_repository_name = self.default_repository_name

      @finders[repository_name] ||= if repository_name == default_repository_name
        []
      else
        finders(default_repository_name).dup
      end
    end

    def associated_set name, model, &block
      name    = name.to_sym
      model   = model

      repository_name = repository.name

      finder = {
        name: name,
        model: model,
        block: block,
        many: true
      }

      finders(repository_name) << finder
      descendants.each do |descendant|
        descendant.finders(repository_name) << finder
      end

      create_finder_reader(finder)

      finder
    end

    def create_finder_reader(finder)
      name        = finder[:name]
      reader_name = name.to_s

      return if method_defined?(reader_name)

      finder_module.module_exec do
        define_method reader_name do
          finder.block[self]
        end
      end
    end

    def finder_module
      @finder_module ||= begin
        mod = Module.new
        class_eval do
          include mod
        end
        mod
      end
    end

    module InstanceMethods
      def finders
        model.finders(repository_name)
      end
    end
  end

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
  FormatRegex = /(?:\.(?<format>[^\/]+))?/

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

    def min_representation root, ext
      { uri: uri(root, ext) }
    end

    def representation root, ext, embed, context
      if valid? && valid?(context)
        min_representation(root, ext).tap do |repr|
          properties.select { |property| property.reader_visibility == :public }.each do |property|
            repr[property.name] = property.get(self)
          end
          finders.each do |finder|
            finder[:block][self].tap do |found|
              repr[finder[:name]] = found && if embed
                found.representation(root, ext, embed, :default)
              else
                found.min_representation(root, ext)
              end
            end
          end
          relationships.select { |relationship| relationship.reader_visibility == :public }.each do |relationship|
            relationship.get(self).tap do |found|
              repr[relationship.name] = found && if embed
                found.representation(root, ext, embed, :default)
              else
                found.min_representation(root, ext)
              end
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

      def associated_set *args
        super.tap do |finder|
          block = finder[:block]
          finder[:block] = proc do |parent|
            block[parent].tap do |items|
              items.extend CollectionMethods
              items.api = api
              items.define_singleton_method :plural_name do finder[:name] end
              items.define_singleton_method :base do parent end
            end
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

        def min_representation root, ext
          {
            uri: uri(root, ext),
            count: length
          }
        end

        def representation root, ext, embed, context
          {
            uri: uri(root, ext),
            count: length,
            items: map { |item| item.representation(root, ext, embed, context) }
          }
        end
      end
    end
  end

  class Api < Sinatra::Application
    def self.create_resource api, resource, root_path, plural_name = resource.plural_name, singular_name = resource.singular_name
      resource.api = self
      collection_uri = "#{root_path}#{plural_name}"
      entity_uri = "#{root_path}#{plural_name}\/(?<#{singular_name}_id>[^\.\\\/]+)"

      api.get(/^#{collection_uri}#{FormatRegex}$/) do
        entities = yield(params)
        render(entities.representation(uri("", format), format, false, :default))
      end

      api.get(/^#{entity_uri}#{FormatRegex}$/) do
        entity = yield(params).get(params["#{singular_name}_id".to_sym])
        if entity
          render(entity.representation(uri("", format), format, false, :default))
        else
          halt 404
        end
      end

      unless resource.respond_to? :abstract? and resource.abstract?
        api.put(/^#{entity_uri}#{FormatRegex}$/) do
          entity = yield(params).get(params["#{singular_name}_id".to_sym])
          if entity
            data = api.parse_post request
            entity.attributes = Hash[
              resource.properties.select { |property| property.writer_visibility == :public }.map do |property|
                [ property.name, data[property.name.to_s] ]
              end + resource.relationships.map do |relationship|
                if data.key? relationship.name.to_s
                  [ relationship.name, data[relationship.name.to_s] ]
                elsif data.key? "#{relationship.name}_id"
                  [ relationship.name, relationship.target_model.get(data["#{relationship.name}_id"]) ]
                end
              end.compact
            ]
            if (entity.valid? && entity.valid?(:update))
              entity.save(:update)
            end
            render(entity.representation(uri, format, false, :update))
          else
            halt 404
          end
        end

        api.delete(/^#{entity_uri}#{FormatRegex}$/) do
          entity = yield(params).get(params["#{singular_name}_id".to_sym])
          if entity
            if entity.valid?(:destroy)
              if entity.destroy
                status 204
              else
                status 409
              end
            else
              render(entity.representation(uri, format, false, :destroy))
            end
          else
            halt 404
          end
        end

        api.post(/^#{collection_uri}#{FormatRegex}$/) do
          data = JSON.parse request.body.read
          entity = yield(params).new(Hash[
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
          if (entity.valid? && entity.valid?(:create))
            entity.save(:create)
          end
          status 201
          headers 'Location' => entity.uri(uri, format)
          render(entity.representation(uri, format, false, :create))
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
              render(relationship.get(entity).representation(uri, format, false, :default))
            else
              halt 404
            end
          end
        end
      end

      resource.finders.each do |finder|
        create_resource api, finder[:model], "#{entity_uri}\/", finder[:name] do |params|
          entity = yield(params).get(params[:"#{singular_name}_id"])
          if entity
            finder[:block][entity]
          else
            halt 404
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
