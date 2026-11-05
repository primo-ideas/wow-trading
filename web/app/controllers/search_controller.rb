class SearchController < ApplicationController
  before_action :load_realm

  # The search box asks for `fragment` to fill its suggestions. Without script, the
  # same results are a page of their own.
  def show
    @search = ItemSearch.new(params[:q], current_realm.markets, limit: params[:fragment] ? ItemSearch::LIMIT : 50)
    render partial: "search/results", locals: { search: @search, realm: current_realm } if params[:fragment]
  end
end
