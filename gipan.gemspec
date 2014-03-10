Gem::Specification.new do |gem|
  gem.name = 'gipan'
  gem.summary = "Nemo157's API generator"
  gem.description = 'A simple API generator for turning a set of DataMapper resources into a Sinatra application.'

  gem.authors = ['Nemo157']
  gem.email = 'ghostunderscore@gmail.com'
  gem.homepage = 'http://github.com/Nemo157/gipan'
  gem.license = 'MIT'

  gem.version = '0.1.0'
  gem.date = '2014-03-10'

  gem.files = %w{lib/gipan.rb lib/abstract.rb}
  gem.extra_rdoc_files = %w{LICENSE README.md}

  gem.add_runtime_dependency 'sinatra', '~> 1.4.4'
  gem.add_runtime_dependency 'data_mapper', '~> 1.2.0'
end
