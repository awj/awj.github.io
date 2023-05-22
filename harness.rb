#!/usr/bin/env ruby

require "csv"

load "index.rb"

csv = CSV.read("./city_populations_2022.csv", headers: true, converters: [:integer, :all, :all, :all, :integer])

# Store our CSV as an Array, where each row is represented as a Hash of column names to values.
data = csv.map(&:to_h)

index = Index.declare("state", "city")

data.each do |row|
  index.add(row)
end; nil
