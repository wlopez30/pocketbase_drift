// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:async';

import 'package:flutter/foundation.dart';
import "package:http/http.dart" as http;

import '../../../pocketbase_drift.dart';

abstract class $Service<M extends Jsonable> extends BaseCrudService<M> {
  $Service(this.client, this.service) : super(client);

  final String service;

  @override
  final $PocketBase client;

  @override
  Future<M> getOne(
    String id, {
    String? expand,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
  }) async {
    return fetchPolicy.fetch<M>(
      remote: () => super.getOne(
        id,
        fields: fields,
        query: query,
        expand: expand,
        headers: headers,
      ),
      getLocal: () async {
        final result = await client.db
            .$query(
              service,
              expand: expand,
              fields: fields,
              filter: 'id = "$id"',
            )
            .getSingleOrNull();
        if (result == null) {
          throw Exception(
            'Record ($id) not found in collection $service [cache]',
          );
        }
        return itemFactoryFunc(result);
      },
      setLocal: (value) async {
        await client.db.$create(service, value.toJson());
      },
    );
  }

  @override
  Future<List<M>> getFullList({
    int batch = 200,
    String? expand,
    String? filter,
    String? sort,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
  }) async {
    return fetchPolicy.fetch<List<M>>(
      remote: () => super.getFullList(
        batch: batch,
        expand: expand,
        filter: filter,
        fields: fields,
        sort: sort,
        query: query,
        headers: headers,
      ),
      getLocal: () async {
        final items = await client.db
            .$query(
              service,
              expand: expand,
              fields: fields,
              filter: filter,
              sort: sort,
            )
            .get();
        return items.map((e) => itemFactoryFunc(e)).toList();
      },
      setLocal: (value) async {
        for (final item in value) {
          await client.db.$create(
            service,
            item.toJson(),
          );
        }
      },
    );
  }

  @override
  Future<ResultList<M>> getList({
    int page = 1,
    int perPage = 30,
    String? expand,
    String? filter,
    String? sort,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
  }) async {
    return fetchPolicy.fetch<ResultList<M>>(
      remote: () => super.getList(
        page: page,
        perPage: perPage,
        expand: expand,
        filter: filter,
        fields: fields,
        sort: sort,
        query: query,
        headers: headers,
      ),
      getLocal: () async {
        final limit = perPage;
        final offset = (page - 1) * perPage;
        final items = await client.db
            .$query(
              service,
              limit: limit,
              offset: offset,
              expand: expand,
              fields: fields,
              filter: filter,
              sort: sort,
            )
            .get();
        final results = items.map((e) => itemFactoryFunc(e)).toList();
        final count = await client.db.$count(service);
        final totalPages = (count / perPage).floor();
        return ResultList(
          page: page,
          perPage: perPage,
          items: results,
          totalItems: count,
          totalPages: totalPages,
        );
      },
      setLocal: (value) async {
        for (final item in value.items) {
          await client.db.$create(
            service,
            item.toJson(),
          );
        }
      },
    );
  }

  Future<M?> getOneOrNull(
    String id, {
    String? expand,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
  }) async {
    try {
      final result = await getOne(
        id,
        fetchPolicy: fetchPolicy,
        expand: expand,
        fields: fields,
        query: query,
        headers: headers,
      );
      return result;
    } catch (e) {
      if (client.logging) {
        debugPrint('cannot find $id in $service $e');
      }
    }
    return null;
  }

  Future<void> setLocal(List<M> items) async {
    for (final item in items) {
      await create(body: item.toJson());
    }
  }

  @override
  Future<M> create({
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    List<http.MultipartFile> files = const [],
    Map<String, String> headers = const {},
    String? expand,
    String? fields,
  }) async {
    M? result;
    bool saved = false;

    // TODO: Save files for offline

    if (fetchPolicy.isNetwork) {
      try {
        result = await super.create(
          body: body,
          query: query,
          headers: headers,
          expand: expand,
          files: files,
          fields: fields,
        );
        saved = true;
      } catch (e) {
        final msg = 'Failed to create record $body in $service: $e';
        if (fetchPolicy == FetchPolicy.networkOnly) {
          throw Exception(msg);
        } else {
          debugPrint(msg);
        }
      }
    }

    if (fetchPolicy.isCache) {
      final data = await client.db.$create(
        service,
        {
          ...result?.toJson() ?? body,
          'deleted': false,
          'synced': saved,
          'isNew': !saved ? true : null,
        },
      );
      result = itemFactoryFunc(data);
    }

    return result!;
  }

  @override
  Future<M> update(
    String id, {
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    List<http.MultipartFile> files = const [],
    Map<String, String> headers = const {},
    String? expand,
    String? fields,
  }) async {
    return create(
      body: {...body, 'id': id},
      fetchPolicy: fetchPolicy,
      query: query,
      files: files,
      headers: headers,
      expand: expand,
      fields: fields,
    );
  }

  @override
  Future<void> delete(
    String id, {
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) async {
    bool saved = false;

    if (fetchPolicy.isNetwork) {
      try {
        await super.delete(
          id,
          body: body,
          query: query,
          headers: headers,
        );
        saved = true;
      } catch (e) {
        final msg = 'Failed to delete record $id in $service: $e';
        if (fetchPolicy == FetchPolicy.networkOnly) {
          throw Exception(msg);
        } else {
          debugPrint(msg);
        }
      }
    }

    if (fetchPolicy.isCache) {
      if (saved) {
        await client.db.$delete(service, id);
      } else {
        await update(
          id,
          body: {
            ...body,
            'deleted': true,
            'synced': false,
          },
          query: query,
          headers: headers,
        );
      }
    }
  }
}

class RetryProgressEvent {
  final int total;
  final int current;

  const RetryProgressEvent({
    required this.total,
    required this.current,
  });

  double get progress => current / total;
}