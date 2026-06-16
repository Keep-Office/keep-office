# pyright: reportUnknownMemberType=false, reportUnknownVariableType=false, reportAttributeAccessIssue=false, reportUnknownArgumentType=false, reportAssignmentType=false, reportCallIssue=false
from datetime import date, datetime, timedelta, timezone

from app.models.calendar import Calendar
from app.models.task import Task
from caldav import DAVClient
from caldav.requests import HTTPBearerAuth

# Number of days ahead (including today) to include in the upcoming-events window.
UPCOMING_DAYS = 3


class CaldavClient:
    def __init__(self, base_url: str, token: str) -> None:
        self.base_url = base_url
        self.token = token

        self.client = DAVClient(url=f"{base_url}/remote.php/dav", auth=HTTPBearerAuth(token))

    def get_calendars(self, check_date: date) -> list[Calendar | None]:
        principal = self.client.principal()
        calendars = principal.calendars()

        events_today: list[Calendar | None] = []

        now = datetime.now(timezone.utc)
        window_start = datetime.combine(check_date, datetime.min.time())
        window_end = datetime.combine(check_date + timedelta(days=UPCOMING_DAYS), datetime.max.time())

        for calendar in calendars:
            # expand=False: Nextcloud's CalDAV does not expand recurrences over a
            # multi-day range (returns nothing), so we fetch master objects and
            # parse the icalendar component directly.
            events = calendar.search(start=window_start, end=window_end, event=True, expand=False)
            for event in events:
                for component in event.icalendar_instance.walk("vevent"):
                    summary = component.get("summary")
                    dtstart = component.get("dtstart")
                    dtend = component.get("dtend")
                    if summary is None or dtstart is None:
                        continue
                    start_value = dtstart.dt
                    end_value = dtend.dt if dtend is not None else start_value
                    # Skip events that have already finished (incl. earlier today).
                    if self._is_past(end_value, now):
                        continue
                    events_today.append(
                        Calendar(
                            title=str(summary),
                            start=start_value,
                            end=end_value,
                        )
                    )

        events_today.sort(key=lambda e: self._sort_key(e.start))
        return events_today

    @staticmethod
    def _is_past(value: datetime | date, now: datetime) -> bool:
        # datetime is a subclass of date, so check it first.
        if isinstance(value, datetime):
            if value.tzinfo is None:
                value = value.replace(tzinfo=timezone.utc)
            return value < now
        # All-day events carry a plain date; past only if before today.
        return value < now.date()

    @staticmethod
    def _sort_key(value: datetime | date) -> datetime:
        if isinstance(value, datetime):
            return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return datetime.combine(value, datetime.min.time(), tzinfo=timezone.utc)

    def get_tasks(self) -> list[Task]:
        principal = self.client.principal()
        calendars = principal.calendars()

        tasks_list: list[Task] = []

        for calendar in calendars:
            for task in calendar.todos():
                task_instance = task.vobject_instance.vtodo
                task_summary: str = task_instance.summary.value
                task_start: datetime = task_instance.dtstart.value if hasattr(task_instance, "dtstart") else None
                task_due: datetime = task_instance.due.value if hasattr(task_instance, "due") else None
                tasks_list.append(Task(title=task_summary, start=task_start, end=task_due))

        return tasks_list
