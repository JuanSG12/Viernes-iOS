import Contacts
import ViernesCore

/// Contactos de iOS (`CNContactStore`) para el resolutor central. Con el acceso limitado de iOS 18 solo se ven los contactos
/// que el usuario compartió: se trata como acceso válido y se avisa cuando falta alguien.
final class SystemContactDirectory: ContactDirectory, @unchecked Sendable {
    private let store = CNContactStore()

    static func map(_ status: CNAuthorizationStatus) -> ContactAccess {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func access() async -> ContactAccess { Self.map(CNContactStore.authorizationStatus(for: .contacts)) }

    func requestAccess() async -> ContactAccess {
        _ = try? await store.requestAccess(for: .contacts)
        return await access()
    }

    func allContacts() async throws -> [ContactCard] {
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
                                       CNContactNicknameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
                                       CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var cards: [ContactCard] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let phones = contact.phoneNumbers.map { value -> ContactPhone in
                let label = value.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
                return ContactPhone(label: label, number: value.value.stringValue)
            }
            cards.append(ContactCard(id: contact.identifier, givenName: contact.givenName, familyName: contact.familyName,
                                     nickname: contact.nickname, organization: contact.organizationName, phones: phones,
                                     emails: contact.emailAddresses.map { String($0.value) }))
        }
        return cards
    }
}
