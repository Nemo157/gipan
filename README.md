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
  class Post
    property :id, Serial
    property :created_at, DateTime, writer: :protected
    property :updated_at, DateTime, writer: :protected
    property :deleted_at, ParanoidDateTime, writer: :protected, reader: :protected
    
    property :author, String
    property :name, String, length: 0..100
    property :body, Text
  end
  
  class Comment
    property :id, Serial
    property :created_at, DateTime, writer: :protected
    property :updated_at, DateTime, writer: :protected
    property :deleted_at, ParanoidDateTime, writer: :protected, reader: :protected
    
    property :author, String
    property :body, Text
  end
  
  class Root < GipAN::Api
    resource Post
    resource Comment
    
    root_path 'api'
  end
end
````
