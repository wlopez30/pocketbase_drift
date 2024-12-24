import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:pocketbase/pocketbase.dart';

import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [Services, BlobFiles],
  include: {'sql/search.drift'},
)
class DataBase extends _$DataBase {
  DataBase(DatabaseConnection connection) : super.connect(connection);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          await m.createTable(blobFiles);
        }
      },
    );
  }

  Selectable<Service> search(String query, {String? service}) {
    if (service != null) {
      return _searchService(query, service).map((p0) => p0.record);
    } else {
      return _search(query).map((p0) => p0.record);
    }
  }

  String generateId() => newId();

  String queryBuilder(
    String service, {
    String? fields,
    String? filter,
    String? sort,
    int? offset,
    int? limit,
  }) {
    final baseFields = <String>[
      "id",
      "created",
      "updated",
    ];

    String fixField(
      String field, {
      bool alias = true,
    }) {
      field = field.trim();
      if (field.toLowerCase().contains('count(')) {
        return field;
      }
      if (baseFields.contains(field)) return field;
      var str = "json_extract(services.data, '\$.$field')";
      if (alias) str += ' as $field';
      return str;
    }

    final sb = StringBuffer();
    sb.write('SELECT ');
    if (fields != null && fields.isNotEmpty) {
      final items = fields.split(',');
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        sb.write(fixField(item));
        if (i < items.length - 1) {
          sb.write(', ');
        }
      }
    } else {
      sb.write('*');
    }
    sb.write(' FROM services');
    sb.write(" WHERE service = '$service'");
    if (filter != null && filter.isNotEmpty) {
      // Replace && and || with AND and OR
      if (filter.startsWith('(') && filter.endsWith(')')) {
        filter = filter.substring(1, filter.length - 1);
      }
      filter = filter.replaceAll('&&', 'AND').replaceAll('||', 'OR');
      // Replace fields with json_extract
      // = Equal
      // != NOT equal
      // > Greater than
      // >= Greater than or equal
      // < Less than
      // <= Less than or equal
      // ~ Like/Contains (if not specified auto wraps the right string OPERAND in a "%" for wildcard match)
      // !~ NOT Like/Contains (if not specified auto wraps the right string OPERAND in a "%" for wildcard match)
      // ?= Any/At least one of Equal
      // ?!= Any/At least one of NOT equal
      // ?> Any/At least one of Greater than
      // ?>= Any/At least one of Greater than or equal
      // ?< Any/At least one of Less than
      // ?<= Any/At least one of Less than or equal
      // ?~ Any/At least one of Like/Contains (if not specified auto wraps the right string OPERAND in a "%" for wildcard match)
      // ?!~ Any/At least one of NOT Like/Contains (if not specified auto wraps the right string OPERAND in a "%" for wildcard match)
      final parts = filter.replaceAll('(', '').replaceAll(')', '').multiSplit([' AND ', ' OR ']);
      
      final processedFields = <String>{}; // To keep track of processed fields.
      for (final part in parts) {
        final words = part.split(' ');
        final field = words[0].trim();

        // Check if the field has already been processed.
        if (!processedFields.contains(field)) {
          filter = filter!.replaceAll(
            field,
            fixField(field, alias: false),
          );
          processedFields.add(field); // Mark the field as processed.
        }
      }
      
      sb.write(' AND ($filter)');
    }
    if (sort != null && sort.isNotEmpty) {
      // Example: -created,id
      // - DESC, + ASC
      final parts = sort.split(',');
      if (parts.isNotEmpty) {
        sb.write(' ORDER BY ');
        for (var i = 0; i < parts.length; i++) {
          final part = parts[i];
          if (part.startsWith('-')) {
            sb.write(part.substring(1));
            sb.write(' DESC');
          } else if (part.startsWith('+')) {
            sb.write(part.substring(1));
            sb.write(' ASC');
          } else {
            sb.write(part);
            sb.write(' ASC');
          }
          if (i < parts.length - 1) {
            sb.write(', ');
          }
        }
      }
    }
    if (limit != null) {
      sb.write(' LIMIT $limit');
    }
    if (offset != null) {
      sb.write(' OFFSET $offset');
    }
    return sb.toString();
  }

  Selectable<CollectionModel> $collections({
    String? service,
  }) {
    var str = "SELECT * FROM services WHERE service = 'schema'";
    if (service != null) {
      str += " AND json_extract(services.data, '\$.name') = '$service'";
    }
    final query = customSelect(str).map(parseRow);
    return query.map(CollectionModel.fromJson);
  }

  Selectable<Map<String, dynamic>> $query(
    String service, {
    String? expand,
    String? fields,
    String? filter,
    String? sort,
    int? offset,
    int? limit,
  }) {
    final query = queryBuilder(
      service,
      fields: fields,
      filter: filter,
      sort: sort,
      offset: offset,
      limit: limit,
    );
    print('query: $query');
    return customSelect(
      query,
      readsFrom: {services},
    ).asyncMap((r) async {
      final record = parseRow(r);
      if (expand != null && expand.isNotEmpty) {
        record['expand'] = {};
        final targets = expand.split(',').map((e) => e.trim()).toList();
        for (final target in targets) {
          final levels = target.split('.');
          // Max 6 levels supported
          if (levels.length > 6) {
            throw Exception('Max 6 levels expand supported');
          }

          final nestedExpand = levels.length == 1 ? null : levels.skip(1).join('.');
          final targetField = levels.first;

          // check for indirect expand=comments(post).user
          if (targetField.contains('(') && targetField.contains(')')) {
            // final tCollection = targetField.substring(
            //   0,
            //   targetField.indexOf('('),
            // );
            // final tField = targetField.substring(
            //   targetField.indexOf('(') + 1,
            //   targetField.indexOf(')'),
            // );
            // row.data['expand']['$tCollection($tField)'] = [];
            throw UnimplementedError('Indirect expand not supported yet');
          }

          // Match field to relation
          final collections = await $collections().get();
          final c = collections.firstWhere((e) => e.name == service);
          final schemaField = c.fields.firstWhere(
            (e) => e.name == targetField,
          );
          final targetCollection = collections.firstWhere(
            (e) => e.id == schemaField.data['collectionId'],
          );
          final isSingle = schemaField.data['maxSelect'] == 1;
          final id = record[targetField] as String?;
          final results = <Map<String, dynamic>>[];
          if (id != null) {
            final query = $query(
              targetCollection.name,
              expand: nestedExpand ?? '',
              filter: "id = '$id'",
            );
            if (isSingle) {
              final result = await query.getSingleOrNull();
              if (result != null) {
                results.add(result);
              }
            } else {
              final result = await query.get();
              var items = result.toList();
              if (schemaField.data['maxSelect'] != null) {
                final maxCount = schemaField.data['maxSelect'] as int;
                items = items.take(maxCount).toList();
              }
              results.addAll(items);
            }
          }
          record['expand'][targetField] = results;
        }
      }
      return record;
    });
  }

  Future<int> $count(String service) async {
    final query = queryBuilder(
      service,
      fields: 'COUNT(*)',
    );
    final result = await customSelect(
      query,
      readsFrom: {services},
    ).getSingleOrNull();
    return result?.read<int>('COUNT(*)') ?? 0;
  }

  Map<String, dynamic> parseRow(QueryRow row) {
    const fields = [
      'id',
      'created',
      'updated',
    ];
    final result = <String, dynamic>{};

    if (row.data.containsKey('data')) {
      final data = jsonDecode(row.read<String>('data')) as Map<String, dynamic>;
      result.addAll(data);
    } else {
      result.addAll(row.data);
    }

    for (final field in row.data.keys) {
      if (fields.contains(field)) {
        result[field] = row.readNullable<String>(field);
        continue;
      }
    }

    return result;
  }

  /// Validates data against collection schema
  ///
  /// Throws exception if data is invalid for each field
  ///
  /// Returns true if data is valid
  bool validateData(CollectionModel collection, Map<String, dynamic> data) {
    for (final field in collection.fields) {
      final value = data[field.name];
      if (field.required && value == null) {
        throw Exception('Field ${field.name} is required');
      }
      if (field.type == 'number') {
        if (value != null && num.tryParse(value) == null) {
          throw Exception('Field ${field.name} must be a valid number');
        }
      }
      if (field.type == 'bool') {
        if (value != null && value != true && value != false) {
          throw Exception('Field ${field.name} must be a valid boolean');
        }
      }
      if (field.type == 'date') {
        if (value != null && DateTime.tryParse(value) == null) {
          throw Exception('Field ${field.name} must be a valid date');
        }
      }
      if (field.type == 'text' || field.type == 'editor') {
        if (value != null && value is! String) {
          throw Exception('Field ${field.name} must be a valid string');
        }
      }
      if (field.type == 'url') {
        if (value != null && Uri.tryParse(value) == null) {
          throw Exception('Field ${field.name} must be a valid url');
        }
      }
      if (field.type == 'email') {
        if (value != null && value is! String) {
          // TODO: Regex to validate email?
          throw Exception('Field ${field.name} must be a valid email');
        }
      }
      if (field.type == 'select' || field.type == 'file' || field.type == 'relation') {
        if (value != null && field.data['maxSelect'] != null) {
          if (field.data['maxSelect'] == 1 && value is! String) {
            throw Exception('Field ${field.name} must be a valid string');
          } else if (field.data['maxSelect'] != 1 && value is! List) {
            throw Exception('Field ${field.name} must be a valid list');
          }
        }
      }
    }
    return true;
  }

  Future<Map<String, dynamic>> $create(
    String service,
    Map<String, dynamic> data, {
    bool? synced,
    bool? deleted = false,
    bool? isNew,
    bool? local,
    bool validate = false,
  }) async {
    if (data['id'] == '') data.remove('id');
    final id = data['id'] as String?;
    data.remove('id');

    if (validate) {
      assert(service != 'schema', 'Cannot validate collections');
      final collection = await $collections(service: service).getSingle();
      validateData(collection, data);
    }

    String date(String key) {
      final value = data[key];
      if (value is String) return value;
      return DateTime.now().toIso8601String();
    }

    final String created = date('created');
    final String updated = date('updated');

    final item = ServicesCompanion.insert(
      id: id != null ? Value(id) : const Value.absent(),
      service: service,
      data: {
        ...data,
        'synced': synced,
        'deleted': deleted,
        if (isNew != null) 'new': isNew,
        if (local != null) 'local': local,
      },
      created: Value(created),
      updated: Value(updated),
    );

    // if (id != null) {
    //   final existing = await (select(services)
    //         ..where((r) => r.service.equals(service))
    //         ..where((r) => r.id.equals(id)))
    //       .getSingleOrNull();
    //   if (existing != null) {
    //     await (update(services)
    //           ..where((r) => r.id.equals(id))
    //           ..where((r) => r.service.equals(service)))
    //         .write(item);
    //     return $query(service, filter: "id = '$id'").getSingle();
    //   }
    // }

    final result = await into(services).insertReturning(
      item,
      onConflict: DoUpdate((old) => item),
    );
    return $query(service, filter: "id = '${result.id}'").getSingle();
  }

  Future<Map<String, dynamic>> $update(
    String service,
    String id,
    Map<String, dynamic> data, {
    bool? synced,
    bool? deleted = false,
    bool? isNew,
    bool? local,
    bool validate = false,
  }) {
    return $create(
      service,
      {...data, 'id': id},
      synced: synced,
      deleted: deleted,
      isNew: isNew,
      local: local,
      validate: validate,
    );
  }

  Future<void> $delete(
    String service,
    String id, {
    Batch? batch,
  }) async {
    if (batch == null) {
      await (delete(services)
            ..where((r) => r.service.equals(service))
            ..where((r) => r.id.equals(id)))
          .go();
    } else {
      batch.deleteWhere(
        services,
        (r) => r.service.equals(service) & r.id.equals(id),
      );
    }
  }

  Future<void> deleteAll(
    String service, {
    List<String>? ids,
  }) async {
    if (ids != null) {
      return batch((b) async {
        for (final id in ids) {
          await $delete(service, id, batch: b);
        }
      });
    } else {
      final query = delete(services)..where((r) => r.service.equals(service));
      await query.go();
    }
  }

  Future<void> setLocal(
    String service,
    List<Map<String, dynamic>> items, {
    bool removeAll = true,
  }) async {
    // Remove existing
    if (removeAll) {
      await (delete(services)..where((r) => r.service.equals(service))).go();
    }

    // Add all
    await batch((b) async {
      for (final item in items) {
        // if (!removeAll) {
        //   b.deleteWhere(
        //     services,
        //     (r) => r.service.equals(service) & r.id.equals(item['id'] as String),
        //   );
        // }
        final row = ServicesCompanion.insert(
          id: Value(item['id']),
          data: item,
          service: service,
          created: Value((DateTime.tryParse(item['created']) ?? DateTime.now()).toIso8601String()),
          updated: Value((DateTime.tryParse(item['updated']) ?? DateTime.now()).toIso8601String()),
        );
        b.insert(
          services,
          row,
          onConflict: DoUpdate((old) => row),
        );
      }
    });
    // Get all
    final query = select(services)..where((tbl) => tbl.service.equals(service));
    final results = await query.get();
    print('$service: ${results.length}');
  }

  Future<void> setSchema(List<Map<String, dynamic>> items) => setLocal('schema', items);

  // -- Files --

  Selectable<BlobFile> getFile(String recordId, String filename) {
    return select(blobFiles)..where((tbl) => tbl.recordId.equals(recordId) & tbl.filename.equals(filename));
  }

  Future<BlobFile> setFile(
    String recordId,
    String filename,
    Uint8List data, {
    DateTime? expires,
  }) async {
    final existing = await getFile(recordId, filename).get();
    await batch((batch) {
      for (final item in existing) {
        batch.deleteWhere(blobFiles, (tbl) => tbl.rowId.equals(item.id));
      }
    });
    final item = BlobFilesCompanion.insert(
      filename: filename,
      data: data,
      recordId: recordId,
      expiration: expires != null ? Value(expires) : const Value.absent(),
      created: Value(DateTime.now().toIso8601String()),
      updated: Value(DateTime.now().toIso8601String()),
    );
    return await into(blobFiles).insertReturning(
      item,
      onConflict: DoUpdate((old) => item),
    );
  }

  Future<void> deleteFile(String recordId, String filename) async {
    final q = delete(blobFiles)..where((tbl) => tbl.recordId.equals(recordId) & tbl.filename.equals(filename));
    await q.go();
  }
}

extension StringUtils on String {
  List<String> multiSplit(Iterable<String> delimiters) => delimiters.isEmpty ? [this] : split(RegExp(delimiters.map(RegExp.escape).join('|')));
}
