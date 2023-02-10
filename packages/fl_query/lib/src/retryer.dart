import 'dart:async';

import 'package:flutter/foundation.dart';

class RetryConfig {
  final int maxRetries;
  final Duration retryDelay;
  final Duration timeout;

  const RetryConfig({
    required this.maxRetries,
    required this.retryDelay,
    required this.timeout,
  });
}

mixin Retryer<T, E> {
  VoidCallback retryOperation(
    FutureOr<T?> Function() operation, {
    required RetryConfig config,
    required Function(T?) onSuccessful,
    required Function(E?) onFailed,
  }) {
    int retries = 0;
    late Timer timer;
    VoidCallback? cancel;

    void retry() {
      if (retries < config.maxRetries) {
        retries++;
        timer = Timer(config.retryDelay, () async {
          await Future.value(operation()).then((T? data) {
            onSuccessful(data);
          }).catchError((error) {
            if (error is E) onFailed(error);
            retry();
          });
        });
      } else {
        cancel?.call();
      }
    }

    cancel = timer.cancel;

    timer = Timer(config.timeout, retry);

    return cancel;
  }
}
