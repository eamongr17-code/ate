import Foundation
import Testing
@testable import AteKit

@Suite("Email sign-in rules")
struct EmailSignInRulesTests {
    @Test func anAddressIsTrimmedAndLowercased() {
        #expect(EmailSignInRules.address("  Eamon@Gmail.COM \n") == "eamon@gmail.com")
        #expect(EmailSignInRules.address("a.b+ate@sub.example.com.au") == "a.b+ate@sub.example.com.au")
    }

    @Test func whatCannotBeAnAddressSendsNothing() {
        for typed in ["", "eamon", "eamon@", "@gmail.com", "eamon@gmail", "eamon@gmail.c", "a b@gmail.com",
                      "a@@gmail.com", String(repeating: "a", count: 250) + "@x.com"] {
            #expect(EmailSignInRules.address(typed) == nil, "\(typed)")
        }
    }

    @Test func theCodeIsItsDigitsUpToSix() {
        #expect(EmailSignInRules.code("482913") == "482913")
        #expect(EmailSignInRules.code("482 913") == "482913")
        #expect(EmailSignInRules.code("Your code: 482-913!") == "482913")
        #expect(EmailSignInRules.code("4829131234") == "482913")
        #expect(EmailSignInRules.code("٤٨٢") == "")
        #expect(EmailSignInRules.isComplete("48291") == false)
        #expect(EmailSignInRules.isComplete("482913"))
    }

    @Test func aNewCodeWaitsAMinute() {
        let sent = Date(timeIntervalSince1970: 1_000)
        #expect(EmailSignInRules.secondsUntilResend(sentAt: sent, now: sent) == 60)
        #expect(EmailSignInRules.secondsUntilResend(sentAt: sent, now: sent.addingTimeInterval(59.2)) == 1)
        #expect(EmailSignInRules.secondsUntilResend(sentAt: sent, now: sent.addingTimeInterval(60)) == 0)
        #expect(EmailSignInRules.secondsUntilResend(sentAt: sent, now: sent.addingTimeInterval(500)) == 0)
    }

    @Test func emailIsItsOwnProviderInTheNumbers() {
        #expect(AccountEvents.signInStarted(provider: .email).parameters == ["provider": "email"])
        #expect(AccountEvents.signInFailed(provider: .email, reason: .wrongCode).parameters
                == ["provider": "email", "reason": "wrong_code"])
    }
}
