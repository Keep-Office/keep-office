"use client";
import { useState } from "react";
import { useLocalStorage } from "@/app/Common/CustomHooks/useLocalStorage";
import { Avatar } from "antd";
import { CalendarOutlined } from "@ant-design/icons";
import Widget from "@/app/Common/Widget";
import { useFetchWithRefresh } from "@/app/Common/CustomHooks/useFetchWithRefresh";
import moment from "moment";
import CustomList from "@/app/Common/CustomList";

// NextCloud Calendar (CalDAV) — upcoming events
function Calendar({ app }) {
  const [isFavorite, setIsFavorite] = useLocalStorage(
    "calendar_is_favorite",
    false,
  );
  const [page, setPage] = useState(1);

  const today = moment().format("YYYY-MM-DD");

  const {
    data: events,
    loading,
    error,
    onRefresh,
  } = useFetchWithRefresh(`/caldav/calendars/${today}`);

  const items = (Array.isArray(events) ? events : [])
    .filter(Boolean)
    .sort((a, b) => new Date(a?.start) - new Date(b?.start));

  const paginated = items.slice((page - 1) * 3, page * 3);

  return (
    <Widget
      app={app}
      favorite={isFavorite}
      setFavorite={setIsFavorite}
      error={error}
      onRefresh={onRefresh}
      page={page}
      setPage={setPage}
      total={items.length}
    >
      <CustomList
        dataSource={paginated}
        loading={loading}
        className="widget-list"
        renderItem={(item) => (
          <CustomList.Item key={`${item?.title}-${item?.start}`}>
            <CustomList.Item.Meta
              avatar={
                <Avatar
                  icon={<CalendarOutlined style={{ color: "#ffffff" }} />}
                  className="avt-doc"
                  style={{ backgroundColor: "#185ABD" }}
                />
              }
              title={item?.title}
              description={
                item?.start &&
                moment(item?.start).format("DD-MM-YYYY, HH:mm")
              }
            />
          </CustomList.Item>
        )}
      />
    </Widget>
  );
}

export default Calendar;
