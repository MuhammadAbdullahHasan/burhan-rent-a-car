/// Summary produced by every import run -- shown to the owner in the real
/// app's Import screen, asserted against in tests here.
class ReconciliationReport {
  final bool success;
  int rowsRead = 0;
  int customersCreated = 0;
  int customersMerged = 0; // matched an existing customer by phone/CNIC
  int customersFlaggedForReview = 0; // no phone and no CNIC to match on
  int vehiclesCreated = 0;
  int rentalsInserted = 0;
  int placeholdersInserted = 0;
  final List<String> warnings = [];
  final List<String> errors = [];

  ReconciliationReport({this.success = true});

  ReconciliationReport.failure(String fatalError) : success = false {
    errors.add(fatalError);
  }

  @override
  String toString() {
    final buffer = StringBuffer()
      ..writeln('ReconciliationReport(success: $success)')
      ..writeln('  rowsRead: $rowsRead')
      ..writeln('  customersCreated: $customersCreated')
      ..writeln('  customersMerged: $customersMerged')
      ..writeln('  customersFlaggedForReview: $customersFlaggedForReview')
      ..writeln('  vehiclesCreated: $vehiclesCreated')
      ..writeln('  rentalsInserted: $rentalsInserted')
      ..writeln('  placeholdersInserted: $placeholdersInserted');
    if (warnings.isNotEmpty) {
      buffer.writeln('  warnings:');
      for (final w in warnings) {
        buffer.writeln('    - $w');
      }
    }
    if (errors.isNotEmpty) {
      buffer.writeln('  errors:');
      for (final e in errors) {
        buffer.writeln('    - $e');
      }
    }
    return buffer.toString();
  }
}
