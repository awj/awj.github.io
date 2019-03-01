---
layout: post
title:  "Understanding the Elasticsearch Percolator"
date:   2018-04-24 11:02:55 -0700
categories: elasticsearch
---

Elasticsearch is a powerful, feature-packed tool. Their [documentation](https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html) is great, but some pieces are a bit … out there. Beyond that, some of the functionality has changed significantly over the years, so third-party explanations might no longer be accurate.

One fantastic feature that is both unusual and has changed a lot is percolation. I’m going to try to explain that feature, in the context of its current implementation (version 6.2.4). You’ll need a basic understanding of Elasticsearch, specifically [mappings](https://www.elastic.co/guide/en/elasticsearch/reference/6.2/mapping.html) and [search](https://www.elastic.co/guide/en/elasticsearch/reference/6.2/search-request-body.html).

# The Concept
The normal workflow for Elasticsearch is to store documents (as JSON data) in an index, and execute searches (also JSON data) to ask the index about those documents.

Succinctly, percolation reverses that. You store searches and use documents to ask the index about those searches. That’s true, but it’s not particularly actionable information. How percolators are structured has evolved over the years, to the point where we can give a more useful explanation.

Now, percolation revolves around the [percolator](https://www.elastic.co/guide/en/elasticsearch/reference/6.2/percolator.html) mapping field type. This is like any other field type, except that it expects you to assign a search document as the value. When you store data, the index processes this search document into an executable form and saves it for later.

The [Percolate Query](https://www.elastic.co/guide/en/elasticsearch/reference/6.2/query-dsl-percolate-query.html) takes one or more documents and limits results to ones whose stored searches match at least one document. When searching, the percolate query works like any other query element.

# In Depth
Under the hood, this is implemented in about the way you would expect: indexes with percolate fields keep a hidden (in memory) index. Documents listed in your percolate queries are first put in that index, then a normal query is executed against that index to see if the original percolate-field-bearing document matches.

An important point to remember is that this hidden index gets its mappings from the original percolator index. So indexes used for percolate queries need to have mappings appropriate for the original data and the query document data.

This introduces a bit of a management problem, in that your index data and the percolate query documents could use the same field in different ways. A simple answer to that is to use the [object type](https://www.elastic.co/guide/en/elasticsearch/reference/6.2/object.html) to isolate the percolate-relevant mappings from normal document mappings.

Assuming the queries you are using were originally written for another index of actual documents, it makes the most sense to isolate the data going directly into the percolate index and give the root level over to mapping definitions for percolate query documents.

Also, because percolate fields are parsed into searches and saved at index time, you likely will need to reindex percolate documents after upgrading to take advantage of any optimizations to the system.

# An Example
In my opinion, percolator examples are one of the prime contributors to making the tool hard to understand. They tend to be too simple, to the point where it’s hard to distinguish the parts.

In this example, we’re going to build out an index of saved term and price searches for toys. The idea behind it is that users should be able to put in a search term and a max price, then get notified as soon as something matching that term goes below this price. Users should also be able to turn these notifications on and off.

The mapping below implements a percolate index to support this feature. Fields related to the saved search itself are in the `search` object, while fields related to the original toys live at the root level of the mappings.

```json
{
  "mappings": {
    "_doc": {
      "properties": {
        "search": {
          "properties": {
            "query":   { "type": "percolator" },
            "user_id": { "type": "integer" },
            "enabled": { "type": "boolean" }
          },
        },
        "price":       { "type": "float" },
        "description": { "type": "text" }
      }
    }
  }
}
```

Here is what a document that represents a stored search would look like:

```json
{
  "_id": 1,
  "search": {
    "user_id": 5,
    "enabled": true",
    "query": {
      "bool": {
        "filter": [
          { 
            "match": { 
              "description": { "query": "nintendo switch" }
            }
          },
          { "range": { "price": { "lte": 300.00 } } }
        ]
      }
    }
  }
}
```

Note that we are only storing data inside the `search` object field. The mappings for `price` and `description` are just there to support percolate queries.

At query time, we want to use both the plain object fields and the “special” percolator field. This query would check, inside a user’s searches, to see which currently-enabled searches match the document.

```json
{
  "query": {
    "bool": {
      "filter": [
        {
          "percolate" : {
            "field" : "search.query",
            "document" : {
              "description" : "Nintendo Switch",
              "price": 250.00
            }
          }
        },
        { "term": { "search.enabled": true } },
        { "term": { "search.user_id": 5 } }
      ]
    }
  }
}
```

Note that it combines percolate matching of a document against the queries stored in the field with regular term queries to limit which documents we test based on their enabled state and the user id.

# Some Additional Thoughts
Because of the work involved in running queries as part of resolving a percolate filter, you might need to pay extra attention to shards/replicas for a percolate index. Each shard reduces the number of queries any one machine may have to run, by reducing the number of search-bearing documents to evaluate.

Percolate queries have an option to get documents from another index inside the cluster. This takes the form of a literal GET request, so there’s not much benefit in trying to keep shards from the two indices on the same nodes.
