AUDIT (
  name detect_contact_matched_but_not_matched,
  blocking TRUE
);

with non_matches AS (
SELECT distinct contact_id
FROM @this_model
WHERE lead_id is null and valid_to is null
)

, matches AS (
SELECT distinct contact_id
FROM @this_model
WHERE lead_id is not null and valid_to is null
)

select matches.contact_id
from matches
join non_matches
on matches.contact_id = non_matches.contact_id