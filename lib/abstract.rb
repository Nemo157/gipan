module GipAN
  module Abstract
    def self.included entity
      entity.class_eval do
        validates_with_method :type, :validate_type

        def self.abstract?
          true
        end

        def abstract?
          self.class.abstract?
        end

        def self.inherited subclass
          subclass.class_eval do
            def self.abstract?
              false
            end
          end
          super
        end

        def validate_type
          if abstract?
            [ false, "Cannot save an abstract entity type" ]
          else
            true
          end
        end
      end
      super
    end
  end
end
