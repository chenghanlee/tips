## Problem Solving

- Ask why 5–15 times to find the root problem. Stop when two more whys do not change the answer.
- Start with first principles, then use Occam's razor and the 80/20 rule to find the simplest working solution for the root problem

## Software Design

- Use Elixir and Phoenix Framework idioms, standards, and conventions.
- Use proven architecture, standards, and conventions from widely used software similar to the
project that the user is building.
- Strive for simple working and elegant solutions. Elegant solutions make complex things seem easy
and obvious. Choose simplicity over elegance when they conflict.
- Build an MVP for fast iteration and finding product-market fit. Avoid unnecessary enterprise complexity. No backwards compatibility.
- Accept necessary complexity when it makes the user's experience simpler. Don't make the implementation look simple by pushing its complexity onto the user. Apply this principle across the software architecture, backend, data model, and frontend.
- "Perfection is achieved, not when there is nothing more to add, but when there is nothing left to take away"

## Testing

- Follow the testing trophy, integration first. TDD means writing the failing ExUnit integration test for the acceptance scenario before the code.
- Unit tests only for pure logic with wide blast radius. End-to-end tests only at milestone gates.

## Code Review and Software Architecture Review

- First, check for immediate, local correctness
- Second, assess each review and its proposed fix's direct and downstream effects on its direct module, feature, or tests.
- Lastly, assess each review and its proposed fix's against the project's software design and implementation as a whole and end to end.

## Writing

- Use plain English. Be direct and concise. Don't use mannered prose.

## Responses to the User

- Write response for a user with ADHD.
