import Foundation
import SwiftData

/// Schema versioning.
///
/// The latest version references the live model types. Each older version keeps frozen copies of
/// the models that changed after it, so SwiftData can recognise stores written by older app
/// versions and migrate them. To change a model: copy its current definition into the latest
/// version's enum as a nested type, add a new version that references the live type, and append a
/// MigrationStage (lightweight where possible). Never edit a frozen copy.
enum TallySeamSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [TallySeamSchemaV1.MoneyTransaction.self, SpendingCategory.self, PaymentMethod.self, Receipt.self,
         RecurringBill.self, Budget.self, AppSettings.self]
    }

    /// MoneyTransaction exactly as shipped in schema 1.0.0 (app builds up to 1.0 (16)). Frozen.
    @Model
    final class MoneyTransaction {
        @Attribute(.unique) var id: UUID
        var transactionDate: Date
        var createdAt: Date
        var updatedAt: Date
        var amountMinorUnits: Int64
        var currencyCode: String
        var merchant: String?
        var title: String
        var notes: String?
        var transactionTypeRaw: String
        var categoryId: UUID?
        var paymentMethodId: UUID?
        var receiptId: UUID?
        var recurringBillId: UUID?
        var sourceRaw: String
        var isVerified: Bool
        var transferGroupId: UUID?
        var isRefund: Bool = false
        var transferDestinationPaymentMethodId: UUID? = nil

        init(id: UUID, transactionDate: Date, amountMinorUnits: Int64, currencyCode: String, title: String,
             transactionTypeRaw: String, isRefund: Bool = false) {
            self.id = id; self.transactionDate = transactionDate; self.createdAt = transactionDate; self.updatedAt = transactionDate
            self.amountMinorUnits = amountMinorUnits; self.currencyCode = currencyCode; self.title = title
            self.transactionTypeRaw = transactionTypeRaw; self.sourceRaw = TransactionSource.manual.rawValue
            self.isVerified = true; self.isRefund = isRefund
        }
    }
}

/// 2.0.0: MoneyTransaction gains `countedMonth` (count a transaction in another month, e.g. a
/// November salary paid in late October). Optional with no value, so existing rows keep their meaning.
enum TallySeamSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [MoneyTransaction.self, SpendingCategory.self, PaymentMethod.self, Receipt.self,
         RecurringBill.self, Budget.self, AppSettings.self]
    }
}

/// 3.0.0: statement import and reconciliation. Adds new models only (no existing model changes),
/// so 2.0.0 keeps referencing the live types and a lightweight stage adds the new tables.
enum TallySeamSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] {
        TallySeamSchemaV2.models + [FinancialAccount.self, ImportSession.self, ImportedStatement.self,
                                    TallySeamSchemaV3.StatementTransaction.self, ReconciliationMatch.self, MerchantAlias.self]
    }

    /// StatementTransaction exactly as shipped in schema 3.0.0 (builds 1.0 (28)–(33)). Frozen.
    @Model
    final class StatementTransaction {
        @Attribute(.unique) var id: UUID
        var statementId: UUID
        var transactionDate: Date
        var postingDate: Date?
        var originalDescription: String
        var normalizedMerchant: String
        var amountMinorUnits: Int64
        var currencyCode: String
        var directionRaw: String
        var kindRaw: String
        var referenceNumber: String?
        var sourcePage: Int
        var sourceLine: Int
        var confidenceRaw: Int
        var isPending: Bool
        var wasEditedByUser: Bool
        var statusRaw: String
        var matchedTransactionId: UUID?

        init(id: UUID, statementId: UUID, transactionDate: Date, description: String, amountMinorUnits: Int64, currencyCode: String,
             directionRaw: String) {
            self.id = id; self.statementId = statementId; self.transactionDate = transactionDate
            self.originalDescription = description; self.normalizedMerchant = description.lowercased()
            self.amountMinorUnits = amountMinorUnits; self.currencyCode = currencyCode; self.directionRaw = directionRaw
            self.kindRaw = StatementLineKind.unknown.rawValue; self.sourcePage = 1; self.sourceLine = 1
            self.confidenceRaw = 2; self.isPending = false; self.wasEditedByUser = false
            self.statusRaw = StatementLineStatus.unmatched.rawValue
        }
    }
}

/// 4.0.0: StatementTransaction gains the optional `runningBalance` printed on bank statements, used
/// to find the exact line where a balance stops adding up.
enum TallySeamSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }
    static var models: [any PersistentModel.Type] {
        TallySeamSchemaV2.models + [FinancialAccount.self, ImportSession.self, ImportedStatement.self,
                                    StatementTransaction.self, ReconciliationMatch.self, MerchantAlias.self]
    }
}

/// 5.0.0: investments and monthly balance snapshots. New models only, so a lightweight stage adds
/// the tables and every existing record is kept as it is.
enum TallySeamSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }
    static var models: [any PersistentModel.Type] {
        TallySeamSchemaV4.models + [Investment.self, MonthlySnapshot.self]
    }
}

/// 6.0.0: split expenses with other people and settle up. New models only, so a lightweight stage
/// adds the tables and every existing record is kept as it is.
enum TallySeamSchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }
    static var models: [any PersistentModel.Type] {
        TallySeamSchemaV5.models + [SplitPerson.self, TransactionSplit.self, SplitLedgerEntry.self]
    }
}

/// 7.0.0: subscription types (Gym & Fitness, Streaming, Car…) under the Subscriptions category.
/// New models only, so a lightweight stage adds the tables and every existing record is kept.
enum TallySeamSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }
    static var models: [any PersistentModel.Type] {
        TallySeamSchemaV6.models + [SubscriptionType.self, SubscriptionLink.self]
    }
}

/// The schema every container opens with.
typealias TallySeamCurrentSchema = TallySeamSchemaV7

enum TallySeamMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [TallySeamSchemaV1.self, TallySeamSchemaV2.self, TallySeamSchemaV3.self, TallySeamSchemaV4.self, TallySeamSchemaV5.self, TallySeamSchemaV6.self, TallySeamSchemaV7.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: TallySeamSchemaV1.self, toVersion: TallySeamSchemaV2.self),
         .lightweight(fromVersion: TallySeamSchemaV2.self, toVersion: TallySeamSchemaV3.self),
         .lightweight(fromVersion: TallySeamSchemaV3.self, toVersion: TallySeamSchemaV4.self),
         .lightweight(fromVersion: TallySeamSchemaV4.self, toVersion: TallySeamSchemaV5.self),
         .lightweight(fromVersion: TallySeamSchemaV5.self, toVersion: TallySeamSchemaV6.self),
         .lightweight(fromVersion: TallySeamSchemaV6.self, toVersion: TallySeamSchemaV7.self)]
    }
}
