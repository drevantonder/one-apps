import Contacts
import Foundation

/// Contacts, through the Contacts framework.
enum ContactsPart {
    static func run(_ function: String, _ input: Input) throws -> Any {
        try Permissions.people()
        let store = CNContactStore()
        switch function {
        case "search":
            let q = try input.text("query")
            var predicates = [CNContact.predicateForContacts(matchingName: q)]
            if q.contains("@") { predicates.append(CNContact.predicateForContacts(matchingEmailAddress: q)) }
            if q.filter(\.isNumber).count >= 6 { predicates.append(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: q))) }
            var found: [String: CNContact] = [:]
            for p in predicates {
                for c in try store.unifiedContacts(matching: p, keysToFetch: keys) { found[c.identifier] = c }
            }
            return found.values.map(json).sorted { ($0["name"] as! String) < ($1["name"] as! String) }.prefix(input.int("limit", or: 25)).map { $0 }
        case "get":
            let id = try input.text("id")
            do {
                return json(try store.unifiedContact(withIdentifier: id, keysToFetch: keys))
            } catch {
                throw Refusal("no contact with id \(id); contacts_search finds them")
            }
        case "me":
            do {
                return json(try store.unifiedMeContactWithKeys(toFetch: keys))
            } catch {
                throw Refusal("this Mac has no card set as the user's own: choose one in Contacts → Card → Make This My Card")
            }
        default:
            throw Refusal("contacts has no function \(function)")
        }
    }

    private static var keys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey, CNContactBirthdayKey, CNContactUrlAddressesKey,
        ] as [CNKeyDescriptor]
    }

    /// A card's name: its person's, or its organization's when it has none.
    static func name(_ c: CNContact) -> String {
        let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? c.organizationName : name
    }

    private static func json(_ c: CNContact) -> [String: Any] {
        func label(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
        let birthday = c.birthday.map { b in
            [b.year, b.month, b.day].compactMap { $0 }.filter { $0 != NSDateComponentUndefined }.map { String(format: "%02d", $0) }.joined(separator: "-")
        }
        return object([
            "id": c.identifier, "name": name(c), "nickname": c.nickname.nonEmpty,
            "organization": c.organizationName.nonEmpty, "job": c.jobTitle.nonEmpty,
            "phones": c.phoneNumbers.isEmpty ? nil : c.phoneNumbers.map { ["label": label($0.label), "number": $0.value.stringValue] },
            "emails": c.emailAddresses.isEmpty ? nil : c.emailAddresses.map { ["label": label($0.label), "address": $0.value as String] },
            "addresses": c.postalAddresses.isEmpty ? nil : c.postalAddresses.map {
                ["label": label($0.label), "address": CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)]
            },
            "birthday": birthday, "urls": c.urlAddresses.isEmpty ? nil : c.urlAddresses.map { $0.value as String },
        ])
    }
}
