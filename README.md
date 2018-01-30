## Overview

Set of adapters for GraphQL query language to the Tarantool data model. Based
on [graphql-lua](https://github.com/bjornbytes/graphql-lua).

The library split to the two parts: GraphQL parser/executor and data accessors.
The GraphQL part defines possible shapes of queries and implements abstract
query executor, but data accessors implement fetching of objects.

### GraphQL part

The GraphQL part operates on *collections* of *objects*. Each collection stored
set of object of specific type. Collections are linked between using
*connections* in order to implement JOINs (looks like nesting one object to
another in a GraphQL query result).

Object types abstracted away from how it stored in database and described using
avro-schema format. Each collection is described using avro schema name and set
of connections, which holds names of source and destination fields must be
equal in linked objects.

A shape of a query is following. Top-level fields are named as collections.
Nested fields named by a connection name.

GraphQL provides facility to filter objects using arguments. Top-level objects
have set of arguments that match fields set (except nested ones derived from
connections). Nested fields (which derived from connections) have arguments set
defined by a data accessor, typically they are support filtering and
pagination.

Nested fields have object type or list of objects type depending of
corresponding connection type: 1:1 or 1:N.

### Data accessor part

Data accessor defines how objects are stored and how connections are
implemented, also it defines set of arguments for connections. So, data
accessors operates on avro schemas, collections and service fields to fetch
objects and connections and indexes to implement JOINing (nesting).

Note: service fields is metadata of an object that is stored, but is not part
of the object.

Currently only *space* data accessor is implemented. It allows to execute
GraphQL queries on data from the local Tarantool's storage called spaces.

It is planned to implement another data accessor that allows to fetch objects
sharded using tarantool/shard module.

## Run tests

```
git clone https://github.com/tarantool/graphql.git
git submodule update --recursive --init
make test
```

## License

Consider LICENSE file for details. In brief:

* graphql/core: MIT (c) 2015 Bjorn Swenson
* all other content: BSD 2-clause (c) 2018 Tarantool AUTHORS