import 'dart:async';

import 'package:async/async.dart';
import 'package:fl_query/src/collections/retry_config.dart';
import 'package:fl_query/src/core/client.dart';
import 'package:fl_query/src/core/mixins/retryer.dart';
import 'package:mutex/mutex.dart';
import 'package:state_notifier/state_notifier.dart';

typedef MutationFn<DataType, VariablesType> = Future<DataType> Function(
  VariablesType variables,
);

class MutationState<DataType, ErrorType, VariablesType> {
  final DataType? data;
  final ErrorType? error;
  final DateTime updatedAt;

  MutationState({
    this.data,
    this.error,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  MutationState<DataType, ErrorType, VariablesType> copyWith({
    DataType? data,
    ErrorType? error,
    DateTime? updatedAt,
  }) {
    return MutationState<DataType, ErrorType, VariablesType>(
      data: data ?? this.data,
      error: error ?? this.error,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }
}

class Mutation<DataType, ErrorType, VariablesType>
    extends StateNotifier<MutationState<DataType, ErrorType, VariablesType>>
    with Retryer<DataType, ErrorType> {
  final String key;

  final RetryConfig retryConfig;

  MutationFn<DataType, VariablesType> _mutationFn;

  Mutation(
    this.key,
    MutationFn<DataType, VariablesType> mutationFn, {
    required this.retryConfig,
  })  : _dataController = StreamController.broadcast(),
        _errorController = StreamController.broadcast(),
        _mutationController = StreamController.broadcast(),
        _mutationFn = mutationFn,
        super(MutationState<DataType, ErrorType, VariablesType>()) {
    // Listen to network changes and cancel any ongoing operations
    bool wasConnected = true;
    _connectivitySubscription = QueryClient.connectivity.onConnectivityChanged
        .listen((isConnected) async {
      try {
        if (!isConnected &&
            wasConnected &&
            _mutex.isLocked &&
            retryConfig.cancelWhenOffline) {
          await _operation?.cancel();
        }
      } finally {
        wasConnected = isConnected;
      }
    });
  }

  final _mutex = Mutex();
  final StreamController<VariablesType> _mutationController;
  final StreamController<DataType> _dataController;
  final StreamController<ErrorType> _errorController;
  CancelableOperation<void>? _operation;
  late final StreamSubscription<bool>? _connectivitySubscription;

  bool get isInactive => !hasListeners;
  bool get isMutating => _mutex.isLocked;
  bool get hasData => state.data != null;
  bool get hasError => state.error != null;

  DataType? get data => state.data;
  ErrorType? get error => state.error;
  Stream<DataType> get dataStream => _dataController.stream;
  Stream<ErrorType> get errorStream => _errorController.stream;
  Stream<VariablesType> get mutationStream => _mutationController.stream;

  Future<void> _operate(VariablesType variables) {
    return _mutex.protect(() async {
      state = state.copyWith();
      _operation = cancellableRetryOperation(
        () {
          _mutationController.add(variables);
          return _mutationFn(variables);
        },
        config: retryConfig,
        onSuccessful: (data) {
          state = state.copyWith(data: data);
          if (data is DataType) {
            _dataController.add(data);
          }
        },
        onFailed: (error) {
          state = state.copyWith(error: error);
          if (error is ErrorType) {
            _errorController.add(error);
          }
        },
      );
    });
  }

  Future<DataType?> mutate(
    VariablesType variables, {
    bool scheduleToQueue = false,
  }) {
    if (isMutating && !scheduleToQueue) {
      return Future.value(state.data);
    }
    return _operate(variables).then((_) => data);
  }

  void updateMutationFn(MutationFn<DataType, VariablesType> mutationFn) {
    if (mutationFn == _mutationFn) return;
    _mutationFn = mutationFn;
  }

  Future<void> reset() async {
    await _operation?.cancel();
    state = MutationState<DataType, ErrorType, VariablesType>();
  }

  @override
  void dispose() {
    _operation?.cancel();
    _connectivitySubscription?.cancel();
    _dataController.close();
    _errorController.close();
    _mutationController.close();
    super.dispose();
  }

  @override
  operator ==(Object other) {
    return identical(this, other) || (other is Mutation && key == other.key);
  }

  @override
  int get hashCode => key.hashCode;

  Mutation<NewDataType, NewErrorType, NewVariablesType>
      cast<NewDataType, NewErrorType, NewVariablesType>() {
    return this as Mutation<NewDataType, NewErrorType, NewVariablesType>;
  }
}
