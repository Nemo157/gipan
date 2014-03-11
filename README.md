GipAN
=====

A simple API generator for turning a set of DataMapper resources into a Sinatra application.

WARNING
-------

GipAN is currently in a pre-release state, Semantic Versioning will **not** be
used until the v1.0 release. There may even be major changes with no version
bump.

The example given below *should* represent a mostly stable external API, since
everything is derived from the DataMapper resources the basics are unlikely to
change.  As new features are added examples will be added once their external
API is likely stable.

Example
-------

Blog based examples are a required part of a Ruby web gem, right?

````ruby
require 'gipan'

module Blog
  # First we define a helper module for entities, everything should have
  # an id, creation time, last update time and deletion time, right?
  module Entity
    def self.included entity
      entity.class_eval do
        include GipAN::Resource
        
        property :id, entity::Serial
        property :created_at, DateTime,
            writer: :protected
        property :updated_at, DateTime,
            writer: :protected
        property :deleted_at, entity::ParanoidDateTime,
            writer: :protected, reader: :protected
      end
    end
  end
  
  # Then we define the entities that exist, in this case just very simple Post
  # and Comment classes.  Each has an author and body, Posts also have a name
  # and a set of Comments.
  class Post
    include Entity
    
    property :author, String
    property :name, String, length: 0..100
    property :body, Text
    
    has n, :comments
  end
  
  class Comment
    include Entity
    
    property :author, String
    property :body, Text
    
    belongs_to :post
  end
  
  # Finally we define the API and what resources should be accessible at the top
  # level.
  #
  # In this case we've added the Comment resource to the top level so all
  # comments will be accessible at http://server/api/comments as well as being
  # able to access the scoped comments of a post at
  # http://server/api/posts/:post_id/comments.
  #
  # We could have not added the resource here and it would only be available as
  # a sub-resource on a post.
  class Api < GipAN::Api
    root_path 'api'
    
    resource Post
    resource Comment
  end
end

# We finalize DataMapper and create the tables then finalize the api to generate
# the Sinatra routes and finally run the Api as a Rack application.
DataMapper.finalize
DataMapper.auto_upgrade!
Blog::Api.finalize
run Blog::Api
````
