import 'dart:async';

import 'package:async/async.dart';
import 'package:collection/collection.dart';
import 'package:fl_query/fl_query.dart';
import 'package:fl_query/src/core/mixins/retryer.dart';
import 'package:fl_query/src/core/mixins/validation.dart';
import 'package:hive_flutter/adapters.dart';
import 'package:mutex/mutex.dart';
import 'package:state_notifier/state_notifier.dart';

typedef InfiniteQueryFn<DataType, PageType> = FutureOr<DataType?> Function(
    PageType page);
typedef InfiniteQueryNextPage<DataType, PageType> = PageType? Function(
  PageType lastPage,
  DataType lastPageData,
);

class InfiniteQueryPage<DataType, ErrorType, PageType> with Invalidation {
  final PageType page;
  final DataType? data;
  final ErrorType? error;

  final DateTime updatedAt;
  final Duration staleDuration;

  const InfiniteQueryPage({
    required this.page,
    this.data,
    this.error,
    required this.updatedAt,
    required this.staleDuration,
  });

  InfiniteQueryPage<DataType, ErrorType, PageType> copyWith({
    DataType? data,
    ErrorType? error,
  }) {
    return InfiniteQueryPage<DataType, ErrorType, PageType>(
      page: page,
      updatedAt: DateTime.now(),
      staleDuration: staleDuration,
      data: data ?? this.data,
      error: error ?? this.error,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is InfiniteQueryPage<DataType, ErrorType, PageType> &&
        other.page == page;
  }

  @override
  int get hashCode => page.hashCode;
}

class InfiniteQueryState<DataType, ErrorType, PageType> {
  final Set<InfiniteQueryPage<DataType, ErrorType, PageType>> pages;

  InfiniteQueryState({
    required this.pages,
  });

  PageType get lastPage => pages.last.page;

  InfiniteQueryState<DataType, ErrorType, PageType> copyWith(
      {Set<InfiniteQueryPage<DataType, ErrorType, PageType>>? pages}) {
    return InfiniteQueryState<DataType, ErrorType, PageType>(
      pages: pages ?? this.pages,
    );
  }
}

class PageEvent<T, P> {
  final P page;
  final T data;
  const PageEvent(this.page, this.data);

  factory PageEvent.fromPage(
    InfiniteQueryPage page,
  ) {
    return PageEvent(page.page as P, page.data as T);
  }
}

class InfiniteQuery<DataType, ErrorType, PageType>
    extends StateNotifier<InfiniteQueryState<DataType, ErrorType, PageType>>
    with Retryer<DataType, ErrorType> {
  final String key;
  final RetryConfig retryConfig;
  final RefreshConfig refreshConfig;
  final JsonConfig<DataType>? jsonConfig;

  final PageType _initialParam;

  InfiniteQueryFn<DataType, PageType> _queryFn;
  InfiniteQueryNextPage<DataType, PageType> _nextPage;

  InfiniteQuery(
    this.key,
    InfiniteQueryFn<DataType, PageType> queryFn, {
    required InfiniteQueryNextPage<DataType, PageType> nextPage,
    required PageType initialParam,
    required this.retryConfig,
    required this.refreshConfig,
    this.jsonConfig,
  })  : _initialParam = initialParam,
        _dataController = StreamController.broadcast(),
        _errorController = StreamController.broadcast(),
        _box = Hive.lazyBox(QueryClient.infiniteQueryCachePrefix),
        _queryFn = queryFn,
        _nextPage = nextPage,
        super(InfiniteQueryState<DataType, ErrorType, PageType>(
          pages: {
            InfiniteQueryPage<DataType, ErrorType, PageType>(
              page: initialParam,
              updatedAt: DateTime.now(),
              staleDuration: refreshConfig.staleDuration,
            ),
          },
        )) {
    if (jsonConfig != null) {
      _mutex.protect(() async {
        final Map? json = await _box.get(key);
        if (json != null) {
          state = state.copyWith(
            pages: json.entries
                .map(
                  (entry) => InfiniteQueryPage<DataType, ErrorType, PageType>(
                    page: entry.key as PageType,
                    data: jsonConfig!.fromJson(
                        Map.castFrom<dynamic, dynamic, String, dynamic>(
                      entry.value,
                    )),
                    // this makes the page loaded from cache `stale`
                    updatedAt:
                        DateTime.now().subtract(refreshConfig.staleDuration),
                    staleDuration: refreshConfig.staleDuration,
                  ),
                )
                .toSet(),
          );
        }
      }).then((_) {
        if (hasListeners) {
          return fetch();
        }
      });
    }
    if (refreshConfig.refreshInterval > Duration.zero)
      Timer.periodic(refreshConfig.refreshInterval, (_) async {
        await Future.wait(
          state.pages.map((page) async {
            if (page.isStale) {
              return await refresh(page.page);
            }
          }),
        );
      });
  }

  final _mutex = Mutex();
  final LazyBox _box;
  final StreamController<PageEvent<DataType, PageType>> _dataController;
  final StreamController<PageEvent<ErrorType, PageType>> _errorController;

  CancelableOperation<void>? _operation;

  List<DataType> get pages =>
      state.pages.map((e) => e.data).whereType<DataType>().toList();
  List<ErrorType> get errors =>
      state.pages.map((e) => e.error).whereType<ErrorType>().toList();
  PageType get lastPage => state.lastPage;
  Stream<PageEvent<DataType, PageType>> get dataStream =>
      _dataController.stream;
  Stream<PageEvent<ErrorType, PageType>> get errorStream =>
      _errorController.stream;

  PageType? get getNextPage {
    final lastPageData = state.pages
        .firstWhereOrNull((e) => e.data is DataType && e.page == lastPage)
        ?.data;

    if (lastPageData == null) return null;

    return _nextPage(lastPage, lastPageData);
  }

  bool get isLoadingPage => !hasPageData && !hasPageError && _mutex.isLocked;
  bool get isRefreshingPage => (hasPageData || hasPageError) && _mutex.isLocked;
  bool get isInactive => !hasListeners;

  bool get hasPages => pages.isNotEmpty;
  bool get hasErrors => errors.isNotEmpty;

  bool get hasPageData => !hasPages ? false : state.pages.last.data != null;
  bool get hasPageError => !hasPages ? false : state.pages.last.error != null;

  bool get hasNextPage => getNextPage != null;

  Future<void> _operate(PageType page) {
    return _mutex.protect(() async {
      state = state.copyWith();
      _operation = cancellableRetryOperation(
        () => _queryFn(page),
        config: retryConfig,
        onSuccessful: (data) async {
          final dataPage = state.pages
              .firstWhere(
                (e) => e.page == page,
                orElse: () => InfiniteQueryPage<DataType, ErrorType, PageType>(
                  page: page,
                  updatedAt: DateTime.now(),
                  staleDuration: refreshConfig.staleDuration,
                ),
              )
              .copyWith(data: data, error: null);
          state = state.copyWith(
            pages: {...state.pages..remove(dataPage), dataPage},
          );
          if (dataPage.data is DataType) {
            _dataController.add(PageEvent.fromPage(dataPage));
            if (jsonConfig != null) {
              await _box.put(
                key,
                Map.fromEntries(
                  state.pages.map(
                    (e) => MapEntry(
                      e.page,
                      e.data != null ? jsonConfig!.toJson(e.data!) : null,
                    ),
                  ),
                ),
              );
            }
          }
        },
        onFailed: (error) {
          final errorPage = state.pages
              .firstWhere(
                (e) => e.page == page,
                orElse: () => InfiniteQueryPage<DataType, ErrorType, PageType>(
                  page: page,
                  updatedAt: DateTime.now(),
                  staleDuration: refreshConfig.staleDuration,
                ),
              )
              .copyWith(error: error);
          state = state.copyWith(
            pages: {
              ...state.pages..remove(errorPage),
              errorPage,
            },
          );
          if (errorPage.error is ErrorType)
            _errorController.add(PageEvent.fromPage(errorPage));
        },
      );
    });
  }

  Future<DataType?> fetch() async {
    final lastPage = state.lastPage;
    if (_mutex.isLocked || hasPageData || hasPageError)
      return state.pages.last.data;
    return await _operate(lastPage).then((_) => state.pages.last.data);
  }

  Future<DataType?> refresh([PageType? page]) async {
    page ??= lastPage;
    if (_mutex.isLocked)
      return state.pages.firstWhereOrNull((e) => e.page == page)?.data;
    return await _operate(page!).then((_) {
      return state.pages.firstWhereOrNull((e) => e.page == page)?.data;
    });
  }

  Future<List<DataType>?> refreshAll() async {
    if (_mutex.isLocked) return pages;
    return await Future.wait(
      state.pages.map((e) => _operate(e.page)),
    ).then((_) => pages);
  }

  Future<DataType?> fetchNext() async {
    final nextPage = getNextPage;
    if (_mutex.isLocked || nextPage == null) {
      return state.pages.lastOrNull?.data;
    }
    return await _operate(nextPage).then((_) {
      return state.pages.firstWhereOrNull((e) => e.page == nextPage)?.data;
    });
  }

  void updateQueryFn(InfiniteQueryFn<DataType, PageType> queryFn) {
    if (_queryFn == queryFn) return;
    _queryFn = queryFn;
    if (refreshConfig.refreshOnQueryFnChange) {
      refreshAll();
    } else {
      Future.wait(
        state.pages.map((page) async {
          if (page.isStale) {
            return await refresh(page.page);
          }
        }),
      );
    }
  }

  void updateNextPageFn(InfiniteQueryNextPage<DataType, PageType> nextPage) {
    if (_nextPage == nextPage) return;
    _nextPage = nextPage;
  }

  void setPageData(PageType page, DataType data) {
    final newPage = state.pages
        .firstWhere(
          (e) => e.page == page,
          orElse: () => InfiniteQueryPage<DataType, ErrorType, PageType>(
            page: page,
            updatedAt: DateTime.now(),
            staleDuration: refreshConfig.staleDuration,
          ),
        )
        .copyWith(data: data);

    state = state.copyWith(
      pages: {
        ...state.pages..remove(newPage),
        newPage,
      },
    );
  }

  Future<void> reset() async {
    await _operation?.cancel();
    state = state.copyWith(pages: {
      InfiniteQueryPage<DataType, ErrorType, PageType>(
        page: _initialParam,
        updatedAt: DateTime.now(),
        staleDuration: refreshConfig.staleDuration,
      )
    });
    _box.delete(key);
  }

  @override
  RemoveListener addListener(
    Listener<InfiniteQueryState<DataType, ErrorType, PageType>> listener, {
    bool fireImmediately = true,
  }) {
    if (refreshConfig.refreshOnMount) {
      refreshAll();
    } else {
      Future.wait(
        state.pages.map((page) async {
          if (page.isStale) {
            return await refresh(page.page);
          }
        }),
      );
    }
    return super.addListener(listener, fireImmediately: fireImmediately);
  }

  @override
  operator ==(Object other) =>
      identical(this, other) || other is InfiniteQuery && key == other.key;

  @override
  int get hashCode => key.hashCode;

  InfiniteQuery<NewDataType, NewErrorType, NewPageType>
      cast<NewDataType, NewErrorType, NewPageType>() {
    return this as InfiniteQuery<NewDataType, NewErrorType, NewPageType>;
  }
}
