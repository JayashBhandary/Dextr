class DextrError implements Exception {
  const DextrError(this.message, {this.cause, this.stack});
  final String message;
  final Object? cause;
  final StackTrace? stack;

  @override
  String toString() => 'DextrError: $message${cause != null ? ' ($cause)' : ''}';
}

class ConnectError extends DextrError {
  const ConnectError(super.message, {super.cause, super.stack});
}

class QueryError extends DextrError {
  const QueryError(super.message, {super.cause, super.stack});
}

class CapabilityError extends DextrError {
  const CapabilityError(super.message);
}
