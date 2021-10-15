---
layout: post
title:  "Thinking about caching"
date:   2019-02-05 19:12:31 -0700
categories: [caching, performance]
excerpt: >-
    Or: how to talk yourself out of one of the hardest problems in computers
---

Caching is one of those weird things in programming, like inheritance and concurrency, where everyone parrots the line about how tough it is then *immediately* turns to it when they have a problem.

Chances are good that *somewhere* in your app, you've got a cache. Maybe it's explicitly coded, or maybe it's implicit in headers set as part of sending data over the wire.

Chances are *also* pretty good that at least some of that caching is *making things slower*. In this post I'll talk through how to think about caching, and more importantly how to figure out when you can just avoid doing it.

# First, applicable scope
It's worth highlighting that I'm *only* talking about read-through caches here. In other words ones where we only "update" the cache after finding out that it's empty/expired while we're trying to fetch data from it. It's one of the most common forms of caching out there.

The "standard" [Rails low-level cache](https://guides.rubyonrails.org/caching_with_rails.html#low-level-caching) is an example of this, as are most of the other forms of Rails caching, and the caching offered by most other web frameworks.

There are other caching options out there that might change the thought process, so if you're looking at one of those be careful just blindly using this logic.

# Good reasons for caching
Before we get into "is a cache worthwhile" questions, let's talk through the reasons you might be adding caching.

## Efficiency
This *the big one*. You're doing a bunch of work to obtain results that don't change, so saving the results avoids re-doing that work.

The goal here is to increase throughput and improve user experiences by making things faster.

Although making things faster is *generally* an improvement for users, it's important to *qualify* how much of an improvement we're talking about. Optimizing a 10ms request into a 1ms request isn't particularly useful outside of some extreme corner cases. 10ms already *feels* fast, so users won't know that we've done something to make it even faster.

Thankfully, there's been some study in this area.

First off, we'll look to [Jakob Nielsen](https://www.nngroup.com/articles/response-times-3-important-limits/) for some important thresholds:

* < 0.1s - feels instantaneous
* < 1.0s - keep your flow of thought
* < 10.0s - keep your focus

A cache that moves your user from one of these "tiers" into another is doing something very useful, even if the overall improvement number doesn't seem impressive.

Second, we'll look at [Neil Patel](https://neilpatel.com/blog/loading-time/) (as referred to us by [Google Analytics help](https://support.google.com/analytics/answer/4589209?hl=en)) to figure out that we see a 7% bounce rate increase for every 1s of load time.

So, in general, we can regard 1s increments as valuable changes, >10s request times as extremely problematic, and moving under 0.1s as a huge improvement.

## Insulating a data store
This is also a common reason for caching. It's subtly different from "efficiency" in that your goal isn't speed, but availability. You're trying to protect your data store from workloads it can't handle by avoiding some of the work.

This requires a bit of different thought and planning, because scenarios where your cache isn't available become a problem. For example, if all of your frontend servers toss their in-memory caches during a deployment, those caches won't be insulating the data store during that window.

It's not uncommon to *initially* deploy a cache for efficiency reasons, only to find out that request growth turned it into a "insulate the data store" cache.

# Bad reasons for caching
There are a few common cases where people *think* the solution to a problem is caching, when in reality it's somewhere between a Band-Aid and actually harmful.

## Very slow queries
You cannot use read-through caching to "get around" request timeouts. If you have cases where load times are approaching your timeouts, all a cache is going to do is make the error intermittent. That's better than nothing, but not actually fixing the whole problem.

The good news is that in most cases, you can probably do something to speed up the queries. Often queries are either over-fetching data or filtering against columns that aren't properly indexed.

## Slow view fragments
Similar to the above about queries, sometimes people turn to caching to solve problems with request timeouts during view rendering. Again, this isn't going to actually solve the problem, just (maybe) push it off for a bit.

Look for N+1 query behavior. Are you loading records one-request-at-a-time when you don't need to? Are you loading too much data in a page?

## It "might" turn out to be slow
Often people slap caching on top of things they *think* will be slow. Equally often, this is the wrong assumption. It's worth remembering that caching is cheap but not free.

# The costs of caching
The costs of caching start with the simplest, and possibly least relevant, decision. Can you afford the server cost? Either you're caching on some shard resource like Redis, or you're doing filesystem/memory caching. In either case you're increasing resource usage somewhere and may have to pay for that.

The largest "cost" of caching lies outside your servers. Caches are *very* hard to reason about, which makes them easy to get wrong, which can cause all kinds of havoc.

In a system without caching, every result simply is what the source of truth says it is. A user changes their name, that gets committed to the database, the very next page shows their new name. Easy peasy.

When caching is involved, any failure to invalidate caches means what your database tells you should happen isn't necessarily what does. This can create some really confusing situations with users, ultimately undermining their trust in your system. In worst cases, it can cause flat out incorrect behavior because something is acting off cached results that are wrong.

Beyond user-facing consequences, code that deals with caching is also simply *more* code. It's more work to update, and every place where relevant data changes needs to *also* worry about caching concerns. Often it's not too hard to wrap that up and hide those details, but they're still there waiting for someone to decide to sidestep the common path.

Ultimately, we have to weigh *how much caching benefits* against these costs. Unfortunately, the first of those is easily quantifiable and the second is highly subjective.

# The caching equation
When trying to answer "is a cache making things faster", there's a relatively simple formula to use. Keep in mind that our cache system is its own data store, with its own access time.

```ruby
hit_rate # % of cache lookups with validly cached data
miss_rate # 100 - hit_rate
lookup_time # time (ms) to consult the cache (hit or miss)
query_time # time(ms) to run the query
cached_query_time = (hit_rate * lookup_time) + (miss_rate * (lookup_time + query_time))
```

The difference between `cached_query_time` and `query_time` is how much caching is helping (or possibly hurting) you.

The beauty of this is that you can plug it into a spreadsheet and play with the numbers. Fill in what you think the hit rate would be, along with average lookup and access times, and you're able to tweak numbers to explore the benefits before doing much coding.

# What is a "good" hit rate
This is a pretty natural question as part of caching decision making, but I think in some ways it's the wrong question.

The right question is "is caching worth it", and your hit rate is only part of that evaluation.

If the *benefit* you're looking for is in user experience, then how often will caching move users between those 0.1/1/10 second thresholds? How much developer complexity and user uncertainty is it adding?

If the *benefit* you want is insulating your data store, how effectively is it doing that? How much load are you eliminating? Are you protected in high usage scenarios?

This isn't to say that hit rates aren't important, they definitely can be, just that hard and fast numbers aren't the best way to evaluate this problem.

# Tradeoffs involving hit rate


# The complex caching equation
[WTF did I intend here?]

# Some caveats
