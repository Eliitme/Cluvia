import Foundation

/// Server-side printed list (`meta.k8s.io/v1 Table`): the same columns `kubectl get` shows, including CRD
/// `additionalPrinterColumns`, so the client needs no per-kind column knowledge.
public struct ResourceTable: Sendable {
    public var columns: [TableColumn]
    public var rows: [TableRow]
    public var resourceVersion: String?

    public static let accept = "application/json;as=Table;v=v1;g=meta.k8s.io,application/json"
    /// Skipped while parsing list/watch tables: `managedFields` is ~80% of a pod row and no list view uses it.
    static let omittedKeys: Set<String> = ["managedFields"]

    init(_ json: JSONValue) {
        resourceVersion = json[path: "metadata", "resourceVersion"]?.stringValue
        if json["kind"]?.stringValue == "Table" {
            columns = (json["columnDefinitions"]?.arrayValue ?? []).map(TableColumn.init)
            rows = (json["rows"]?.arrayValue ?? []).map(TableRow.init)
        } else {
            // Some aggregated APIs ignore the Table request and answer with a plain list (or, in a watch event,
            // a plain object). Fall back to name + creation time so the collection still renders.
            columns = TableColumn.fallback
            rows = (json["items"]?.arrayValue ?? [json]).map(TableRow.fallback)
        }
    }
}

public struct TableColumn: Sendable, Hashable {
    public let name: String
    public let type: String
    public let format: String
    /// 0 = always shown; higher = wide-output only.
    public let priority: Int

    static let fallback = [
        TableColumn(name: "Name", type: "string", format: "name", priority: 0),
        TableColumn(name: "Age", type: "string", format: "date-time", priority: 0),
    ]

    init(name: String, type: String, format: String, priority: Int) {
        self.name = name
        self.type = type
        self.format = format
        self.priority = priority
    }

    init(_ json: JSONValue) {
        name = json["name"]?.stringValue ?? ""
        type = json["type"]?.stringValue ?? "string"
        format = json["format"]?.stringValue ?? ""
        priority = Int(json["priority"]?.intValue ?? 0)
    }
}

/// One printed row plus the object's metadata (`includeObject=Metadata`).
public struct TableRow: Sendable, Hashable, Identifiable {
    public let cells: [JSONValue]
    public let object: Unstructured

    public var id: ObjectKey { object.key }

    init(_ json: JSONValue) {
        cells = json["cells"]?.arrayValue ?? []
        object = Unstructured(Self.slimmed(json["object"] ?? .object([:])))
    }

    /// Row for a full object when the server did not print a table; cells match `TableColumn.fallback`.
    static func fallback(_ json: JSONValue) -> TableRow {
        let object = Unstructured(json)
        return TableRow(
            cells: [.string(object.name), json[path: "metadata", "creationTimestamp"] ?? .null],
            object: Unstructured(slimmed(json))
        )
    }

    init(cells: [JSONValue], object: Unstructured) {
        self.cells = cells
        self.object = object
    }

    /// Drops metadata no list view needs but that can dominate row size, keeping thousands of cached rows
    /// cheap. Detail views fetch the full object.
    static func slimmed(_ object: JSONValue) -> JSONValue {
        guard case var .object(fields) = object, case var .object(metadata)? = fields["metadata"] else { return object }
        metadata["managedFields"] = nil
        if case var .object(annotations)? = metadata["annotations"] {
            annotations["kubectl.kubernetes.io/last-applied-configuration"] = nil
            metadata["annotations"] = annotations.isEmpty ? nil : .object(annotations)
        }
        fields["metadata"] = .object(metadata)
        return .object(fields)
    }
}
