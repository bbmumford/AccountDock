import Foundation

extension String {
    /// Obfuscates an email address by showing only the first few characters of the username,
    /// and masking the rest, including the domain.
    /// Example: "example@domain.com" -> "exa***@***.***"
    /// If the string is not a valid email but contains an email, it will only obfuscate the email.
    /// If the string is just a regular string, it will return the original string.
    func obfuscatedEmail() -> String {
        // Obfuscate emails within the string
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        do {
            let regex = try NSRegularExpression(pattern: emailRegex, options: .caseInsensitive)
            let nsString = self as NSString
            let results = regex.matches(in: self, options: [], range: NSRange(location: 0, length: nsString.length))
            
            guard !results.isEmpty else { return self }
            
            var modifiedString = self
            // Replace from the end to the beginning so ranges remain valid
            for result in results.reversed() {
                let matchedEmail = nsString.substring(with: result.range)
                let obfuscated = matchedEmail.obfuscateSingleEmail()
                
                let start = modifiedString.index(modifiedString.startIndex, offsetBy: result.range.location)
                let end = modifiedString.index(start, offsetBy: result.range.length)
                modifiedString.replaceSubrange(start..<end, with: obfuscated)
            }
            return modifiedString
        } catch {
            return self
        }
    }
    
    private func obfuscateSingleEmail() -> String {
        let parts = self.split(separator: "@")
        guard parts.count == 2 else { return self }
        let username = String(parts[0])
        let domain = String(parts[1])

        let visibleCount = max(1, min(3, username.count))
        let visibleChars = username.prefix(visibleCount)
        let obfuscatedUsername = visibleChars + "*"

        let domainParts = domain.split(separator: ".")
        if let lastPart = domainParts.last {
            return "\(obfuscatedUsername)@*.\(lastPart)"
        }

        return "\(obfuscatedUsername)@*"
    }
}
