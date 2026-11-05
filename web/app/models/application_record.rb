class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Every table belongs to the fetcher.
  def readonly? = true
end
